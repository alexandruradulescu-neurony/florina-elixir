defmodule FlorinaWeb.AuthController do
  @moduledoc "Agent sign-in via Google/Microsoft: login page, OAuth start, callback, logout."
  use FlorinaWeb, :controller
  require Logger

  alias Florina.{Accounts, OAuth, Tenants}
  alias Florina.Integrations.Provider
  import FlorinaWeb.AgentAuth, only: [log_in_agent: 2, log_out_agent: 1]

  @providers ~w(google microsoft)
  # How many in-flight sign-in nonces to remember per browser (covers
  # double-clicks / multiple tabs without unbounded session growth).
  @max_nonces 5

  def login(conn, _params) do
    conn
    |> put_layout(false)
    |> render(:login,
      tenant: conn.assigns.tenant,
      error: Phoenix.Flash.get(conn.assigns.flash, :error)
    )
  end

  # Workspace-agnostic login page (the landing "Log in" button points here). Same
  # template, no tenant — its provider buttons hit the workspace-less start, and the
  # workspace is detected from the verified email at callback.
  def login_global(conn, _params) do
    conn
    |> put_layout(false)
    |> render(:login,
      tenant: nil,
      error: Phoenix.Flash.get(conn.assigns.flash, :error)
    )
  end

  def start(conn, %{"provider" => provider}) when provider in @providers do
    p = String.to_existing_atom(provider)
    slug = conn.assigns.tenant.slug

    # Bind this sign-in to the browser: stash a one-time random nonce in the
    # session and embed it in the signed state. The callback only proceeds if the
    # state's nonce is one this browser issued — so a state minted in someone
    # else's browser (login CSRF) can't be replayed into this one.
    #
    # Keep a small set of recent nonces (not a single slot) so a double-click or
    # a second tab — each minting its own nonce — doesn't invalidate the first
    # attempt's callback.
    nonce = :crypto.strong_rand_bytes(16) |> Base.url_encode64()
    nonces = [nonce | get_session(conn, :oauth_nonces) || []] |> Enum.take(@max_nonces)

    url =
      Provider.impl(p).authorize_url(
        Provider.redirect_uri(provider),
        Provider.sign_state(conn, slug, p, nonce)
      )

    conn
    |> put_session(:oauth_nonces, nonces)
    |> redirect(external: url)
  end

  def start(conn, _),
    do: conn |> put_flash(:error, "Unknown sign-in provider.") |> redirect(to: login_path(conn))

  # Workspace-agnostic OAuth start: identical CSRF-nonce handling to start/2, but the
  # signed state carries NO tenant (nil slug). The callback resolves the workspace
  # from the verified email's domain.
  def start_global(conn, %{"provider" => provider}) when provider in @providers do
    p = String.to_existing_atom(provider)

    nonce = :crypto.strong_rand_bytes(16) |> Base.url_encode64()
    nonces = [nonce | get_session(conn, :oauth_nonces) || []] |> Enum.take(@max_nonces)

    url =
      Provider.impl(p).authorize_url(
        Provider.redirect_uri(provider),
        Provider.sign_state(conn, nil, p, nonce)
      )

    conn
    |> put_session(:oauth_nonces, nonces)
    |> redirect(external: url)
  end

  def start_global(conn, _),
    do: conn |> put_flash(:error, "Unknown sign-in provider.") |> redirect(to: "/login")

  def callback(conn, %{"provider" => provider, "code" => code, "state" => state})
      when provider in @providers do
    p = String.to_existing_atom(provider)

    # Fixed callback path — the tenant is NOT in the URL. Validate the signed state
    # (proves we issued it at `start`) and confirm the nonce is one this browser
    # issued (login-CSRF guard). The state's `tenant_slug` may be nil (workspace-
    # agnostic start), in which case the workspace is resolved from the verified
    # email's domain — see complete_sign_in/5.
    session_nonces = get_session(conn, :oauth_nonces) || []

    with {:ok, %{provider: ^provider, nonce: nonce} = payload}
         when is_binary(nonce) <- Provider.verify_state(conn, state),
         true <- nonce in session_nonces do
      conn = put_session(conn, :oauth_nonces, List.delete(session_nonces, nonce))
      complete_sign_in(conn, p, provider, code, Map.get(payload, :tenant_slug))
    else
      _ ->
        Logger.warning("[AuthController] callback with invalid/forged state")

        conn
        |> put_flash(:error, "Sign-in failed. Please try again.")
        |> redirect(to: "/")
    end
  end

  def callback(conn, %{"error" => error} = params) do
    # `error` is an attacker-controllable query param — inspect it so embedded
    # newlines can't forge extra log lines (log injection).
    Logger.warning("[AuthController] provider error: #{inspect(error)}")

    conn
    |> put_flash(:error, "Authorization was cancelled or failed.")
    |> redirect(to: login_dest(conn, params))
  end

  def callback(conn, params),
    do:
      conn
      |> put_flash(:error, "Invalid callback.")
      |> redirect(to: login_dest(conn, params))

  def logout(conn, _params), do: log_out_agent(conn)

  # Exchange the code and read the verified identity FIRST (both are tenant-
  # independent), THEN resolve the workspace — from the state's slug (per-workspace
  # links) or, when that's nil, the verified email's domain (auto-detection) — and
  # only then pin the schema and finish. The OAuth code is single-use, so it's
  # exchanged exactly once here for both paths.
  defp complete_sign_in(conn, p, provider, code, slug) do
    with {:ok, tokens} <- Provider.impl(p).exchange_code(code, Provider.redirect_uri(provider)),
         {:ok, identity} <- Provider.impl(p).fetch_identity(tokens),
         {:ok, tenant} <- resolve_tenant(slug, identity) do
      # Pin the tenant schema for this request and guarantee it's cleared once the
      # response is sent so a pooled connection process can't carry it into a later,
      # unrelated request (mirrors FlorinaWeb.Plugs.ResolveTenant).
      conn =
        conn
        |> assign(:tenant, tenant)
        |> register_before_send(fn c ->
          Process.delete(:tenant_prefix)
          c
        end)

      Process.put(:tenant_prefix, Tenants.schema_prefix(tenant))
      finish_sign_in(conn, p, identity, tokens)
    else
      {:error, :no_workspace} ->
        conn
        |> put_flash(
          :error,
          "We couldn't find a workspace for that email — please use your company email."
        )
        |> redirect(to: "/login")

      other ->
        # `other` is an {:error, reason} from exchange/identity/slug-lookup; it never
        # carries tokens (those exist only on the {:ok, tokens} success), so it's safe
        # to log.
        Logger.warning(
          "[AuthController] sign-in failed (exchange/identity/workspace): #{inspect(other)}"
        )

        conn
        |> put_flash(:error, "Sign-in failed. Please try again.")
        |> redirect(to: "/")
    end
  end

  # Resolve the workspace from the signed state's slug (per-workspace start) or,
  # when nil, the verified email's domain (workspace-agnostic start). Only an
  # active, fully provisioned tenant is accepted.
  defp resolve_tenant(slug, _identity) when is_binary(slug) do
    case Tenants.get_accessible(slug) do
      %Tenants.Tenant{} = tenant -> {:ok, tenant}
      _ -> {:error, :unknown_workspace}
    end
  end

  defp resolve_tenant(nil, %{email: email, email_verified: true}) when is_binary(email) do
    case Tenants.get_by_email_domain(Tenants.email_domain(email)) do
      %Tenants.Tenant{} = tenant -> {:ok, tenant}
      _ -> {:error, :no_workspace}
    end
  end

  defp resolve_tenant(_slug, _identity), do: {:error, :no_workspace}

  # Runs with the tenant assigned + schema prefix pinned: gate by company email,
  # upsert the agent + calendar credential, log in.
  defp finish_sign_in(conn, p, identity, tokens) do
    with :ok <- gate(identity, conn.assigns.tenant),
         {:ok, agent} <- Accounts.upsert_agent_from_identity(identity),
         {:ok, _cred} <- store_credential(agent, p, identity, tokens) do
      log_in_agent(conn, agent)
    else
      {:error, :forbidden_domain} ->
        conn
        |> put_flash(:error, "Please sign in with your company email address.")
        |> redirect(to: login_path(conn))

      {:error, :inactive} ->
        conn
        |> put_flash(:error, "Your account is deactivated. Contact your administrator.")
        |> redirect(to: login_path(conn))

      {:error, %Ecto.Changeset{} = cs} ->
        # NEVER inspect the whole changeset: its `changes` hold the plaintext
        # OAuth tokens (Cloak only encrypts at the DB boundary). Log just errors.
        Logger.warning(
          "[AuthController] sign-in failed (credential store): #{inspect(cs.errors)}"
        )

        conn
        |> put_flash(:error, "Sign-in failed. Please try again.")
        |> redirect(to: login_path(conn))

      other ->
        Logger.warning("[AuthController] sign-in failed: #{inspect(other)}")

        conn
        |> put_flash(:error, "Sign-in failed. Please try again.")
        |> redirect(to: login_path(conn))
    end
  end

  defp login_path(conn), do: "/t/#{conn.assigns.tenant.slug}/login"

  # The callback has no tenant in the URL, so on error/cancel there's no
  # assigns.tenant. Recover the tenant's login page from the signed state when
  # present; otherwise fall back to the home page.
  defp login_dest(conn, %{"state" => state}) do
    case Provider.verify_state(conn, state) do
      {:ok, %{tenant_slug: slug}} when is_binary(slug) -> "/t/#{slug}/login"
      _ -> "/login"
    end
  end

  defp login_dest(_conn, _params), do: "/"

  defp gate(%{email: email, email_verified: true}, tenant) when is_binary(email) do
    if Tenants.email_domain_allowed?(tenant, email),
      do: :ok,
      else: {:error, :forbidden_domain}
  end

  defp gate(_identity, _tenant), do: {:error, :forbidden_domain}

  defp store_credential(agent, provider, identity, tokens) do
    expires_at =
      case tokens[:expires_in] do
        nil -> nil
        s -> DateTime.add(DateTime.utc_now(), s, :second) |> DateTime.truncate(:second)
      end

    OAuth.upsert_calendar_credential(agent.id, provider, %{
      email: identity.email,
      access_token: tokens.access_token,
      refresh_token: tokens[:refresh_token],
      scopes: String.split(tokens[:scope] || "", " ", trim: true),
      expires_at: expires_at
    })
  end
end

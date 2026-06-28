defmodule FlorinaWeb.AuthController do
  @moduledoc "Agent sign-in via Google/Microsoft: login page, OAuth start, callback, logout."
  use FlorinaWeb, :controller
  require Logger

  alias Florina.{Accounts, OAuth, Tenants}
  alias Florina.Integrations.Provider
  import FlorinaWeb.AgentAuth, only: [log_in_agent: 2, log_out_agent: 1]

  @providers ~w(google microsoft)

  def login(conn, _params) do
    conn
    |> put_layout(false)
    |> render(:login,
      tenant: conn.assigns.tenant,
      error: Phoenix.Flash.get(conn.assigns.flash, :error)
    )
  end

  def start(conn, %{"provider" => provider}) when provider in @providers do
    p = String.to_existing_atom(provider)
    slug = conn.assigns.tenant.slug

    url =
      Provider.impl(p).authorize_url(
        Provider.redirect_uri(provider),
        Provider.sign_state(conn, slug, p)
      )

    redirect(conn, external: url)
  end

  def start(conn, _),
    do: conn |> put_flash(:error, "Unknown sign-in provider.") |> redirect(to: login_path(conn))

  def callback(conn, %{"provider" => provider, "code" => code, "state" => state})
      when provider in @providers do
    p = String.to_existing_atom(provider)

    # Fixed callback path — the tenant is NOT in the URL. Recover it from the
    # signed state (which proves we issued it at `start`), then pin that tenant's
    # schema prefix and assign it so the rest of the flow works as before.
    with {:ok, %{tenant_slug: slug, provider: ^provider}} <- Provider.verify_state(conn, state),
         %Tenants.Tenant{active: true, status: "active"} = tenant <- Tenants.get_by_slug(slug) do
      # Pin the tenant schema for this request, and guarantee it's cleared once the
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
      complete_sign_in(conn, p, provider, code)
    else
      _ ->
        Logger.warning("[AuthController] callback with invalid/forged state or unknown tenant")

        conn
        |> put_flash(:error, "Sign-in failed. Please try again.")
        |> redirect(to: "/")
    end
  end

  def callback(conn, %{"error" => error} = params) do
    Logger.warning("[AuthController] provider error: #{error}")

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

  # Runs with the tenant assigned + its schema prefix pinned: exchange the code,
  # gate by company email, upsert the agent + calendar credential, log in.
  defp complete_sign_in(conn, p, provider, code) do
    with {:ok, tokens} <- Provider.impl(p).exchange_code(code, Provider.redirect_uri(provider)),
         {:ok, identity} <- Provider.impl(p).fetch_identity(tokens),
         :ok <- gate(identity, conn.assigns.tenant),
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
      {:ok, %{tenant_slug: slug}} -> "/t/#{slug}/login"
      _ -> "/"
    end
  end

  defp login_dest(_conn, _params), do: "/"

  defp gate(%{email: email, email_verified: true}, tenant) when is_binary(email) do
    domain = email |> String.split("@") |> List.last() |> String.downcase()
    allowed = Enum.map(tenant.allowed_email_domains || [], &String.downcase/1)
    if domain in allowed, do: :ok, else: {:error, :forbidden_domain}
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

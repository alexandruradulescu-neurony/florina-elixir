defmodule FlorinaWeb.AgentAuth do
  @moduledoc """
  Agent (sales-user) auth: session helpers + plugs (controllers) + an on_mount
  hook (LiveView). The agent lives in the *tenant* DB, so all of these run AFTER
  the tenant is pinned (`ResolveTenant` plug for HTTP, `TenantHook` on_mount for
  LiveView).
  """
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  # Plug.Conn.assign/3 is imported above (for controller plugs).
  # Phoenix.Component.assign/3 is called fully-qualified below (for LiveView sockets)
  # to avoid the compile-time ambiguity between the two arities.

  alias Florina.{Accounts, Authz}

  def log_in_agent(conn, agent) do
    conn
    |> configure_session(renew: true)
    |> put_session(:agent_id, agent.id)
    |> put_session(:agent_tenant_slug, conn.assigns.tenant.slug)
    |> redirect(to: "/t/#{conn.assigns.tenant.slug}/calendar")
  end

  def log_out_agent(conn) do
    slug = conn.assigns.tenant.slug

    # Drop this user's OTHER open live sessions too (a backgrounded tab on a
    # shared machine would otherwise keep working after logout).
    with id when is_integer(id) <- get_session(conn, :agent_id),
         %{} = tenant <- conn.assigns[:tenant] do
      prefix = Florina.Tenants.schema_prefix(tenant)
      Phoenix.PubSub.broadcast(Florina.PubSub, Accounts.user_socket_topic(prefix, id), :revoked)
    end

    conn
    |> configure_session(drop: true)
    |> redirect(to: "/t/#{slug}/login")
  end

  @doc "Plug: assign `:current_agent` from the session if valid + active. Never redirects."
  def fetch_current_agent(conn, _opts) do
    agent =
      with id when is_integer(id) <- get_session(conn, :agent_id),
           true <- conn_tenant_matches?(conn),
           %Accounts.User{active: true} = a <- Accounts.get_user(id) do
        a
      else
        _ -> nil
      end

    assign(conn, :current_agent, agent)
  end

  # The session is bound to the tenant the agent logged in under. The
  # `:tenant_session` router plug rewrites `:tenant_slug` from the URL on every
  # request, so we never trust it for authorization — we compare the *pinned*
  # tenant (`assigns.tenant`) against a separate, login-time key the per-request
  # plug never touches. Without this, an agent of tenant A visiting /t/B/... would
  # be loaded as the same numeric id from tenant B's database (cross-tenant bypass).
  defp conn_tenant_matches?(conn) do
    case conn.assigns[:tenant] do
      %{slug: slug} -> get_session(conn, :agent_tenant_slug) == slug
      _ -> false
    end
  end

  @doc "Plug: require an authenticated, active agent or redirect to tenant login."
  def require_authenticated_agent(conn, _opts) do
    if conn.assigns[:current_agent] do
      conn
    else
      conn
      |> redirect(to: "/t/#{conn.assigns.tenant.slug}/login")
      |> halt()
    end
  end

  @doc "LiveView on_mount — assumes the tenant is already pinned (TenantHook ran first)."
  def on_mount(:ensure_authenticated, _params, session, socket) do
    with id when is_integer(id) <- session["agent_id"],
         true <- socket_tenant_matches?(session, socket),
         %Accounts.User{active: true} = agent <- Accounts.get_user(id) do
      {:cont,
       socket
       |> Phoenix.Component.assign(:current_agent, agent)
       |> watch_for_revocation(agent.id)}
    else
      _ ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/t/#{session["tenant_slug"]}/login")}
    end
  end

  # on_mount(:require_manager, ...) — gate a route to managers only. Must run
  # AFTER :ensure_authenticated (which assigns :current_agent). Non-managers are
  # bounced to their calendar with a flash, so an agent can't open a manager
  # LiveView by typing its URL.
  def on_mount(:require_manager, _params, _session, socket) do
    if Authz.manager?(socket.assigns[:current_agent]) do
      {:cont, socket}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, "That area is for managers only.")
       |> Phoenix.LiveView.redirect(to: "/t/#{socket.assigns.tenant.slug}/calendar")}
    end
  end

  # LiveView counterpart of `conn_tenant_matches?/1`: TenantHook (which runs
  # first) pins + assigns the tenant from `session["tenant_slug"]`; we require
  # the login-time `agent_tenant_slug` to match that pinned tenant.
  defp socket_tenant_matches?(session, socket) do
    case socket.assigns[:tenant] do
      %{slug: slug} -> session["agent_tenant_slug"] == slug
      _ -> false
    end
  end

  # Role/active is only checked at mount. Subscribe the connected socket to this
  # user's revoke topic so a demotion, deactivation, or logout elsewhere drops it
  # immediately — it re-mounts and re-checks (a deactivated user then can't sign
  # in; a demoted one loses the manager screens). Mirrors TenantHook's tenant gate.
  defp watch_for_revocation(socket, user_id) do
    if Phoenix.LiveView.connected?(socket) do
      prefix = Florina.Tenants.schema_prefix(socket.assigns.tenant)
      Phoenix.PubSub.subscribe(Florina.PubSub, Accounts.user_socket_topic(prefix, user_id))

      Phoenix.LiveView.attach_hook(socket, :user_revocation_gate, :handle_info, fn
        :revoked, sock ->
          {:halt, Phoenix.LiveView.redirect(sock, to: "/t/#{sock.assigns.tenant.slug}/login")}

        _msg, sock ->
          {:cont, sock}
      end)
    else
      socket
    end
  end
end

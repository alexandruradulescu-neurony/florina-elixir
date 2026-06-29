defmodule FlorinaWeb.Router do
  use FlorinaWeb, :router

  import FlorinaWeb.AgentAuth, only: [fetch_current_agent: 2, require_authenticated_agent: 2]

  # Conservative CSP (defense-in-depth; HEEx auto-escaping is the primary XSS
  # guard). 'unsafe-inline' is needed for the no-flash theme boot script and
  # framework inline styles; media/img https: allow the HMAC-authenticated call
  # recording audio; ws/wss carry the LiveView socket.
  @csp "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; media-src 'self' https:; connect-src 'self' ws: wss:; frame-ancestors 'self'; base-uri 'self'; object-src 'none'"

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FlorinaWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => @csp}
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :webhook do
    plug :accepts, ["json"]
  end

  pipeline :require_admin do
    plug FlorinaWeb.Plugs.RequireAdmin
  end

  pipeline :resolve_tenant do
    plug FlorinaWeb.Plugs.ResolveTenant
  end

  pipeline :agent_auth do
    plug :fetch_current_agent
    plug :require_authenticated_agent
  end

  # Writes the resolved tenant's slug into the session so a LiveView's on_mount
  # hook can re-resolve it for the websocket connection. Only used on browser
  # routes (which fetch the session); never on the sessionless webhook.
  pipeline :tenant_session do
    plug :put_tenant_slug_in_session
  end

  defp put_tenant_slug_in_session(conn, _opts) do
    Plug.Conn.put_session(conn, :tenant_slug, conn.assigns.tenant.slug)
  end

  scope "/t/:tenant_slug/webhooks", FlorinaWeb.Webhook do
    pipe_through [:webhook, :resolve_tenant]
    post "/elevenlabs", ElevenLabsController, :create
  end

  scope "/", FlorinaWeb do
    pipe_through :browser

    get "/", PageController, :home

    # Workspace-agnostic sign-in: a neutral login page + OAuth start with NO tenant
    # in the URL. The signed `state` carries a nil tenant_slug; the callback resolves
    # the workspace from the verified email's domain (auto-detection).
    get "/login", AuthController, :login_global
    get "/auth/:provider/start", AuthController, :start_global

    # OAuth callback — fixed path (no tenant slug, so ONE redirect URI per provider
    # is registered with Google/Microsoft). The tenant is recovered from the signed
    # `state` (per-workspace links) or from the verified email (workspace-agnostic
    # start); AuthController.callback resolves + pins it.
    get "/auth/:provider/callback", AuthController, :callback
  end

  # Per-tenant sign-in (no agent gate — these establish the session)
  scope "/t/:tenant_slug", FlorinaWeb do
    pipe_through [:browser, :resolve_tenant, :tenant_session]
    get "/login", AuthController, :login
    get "/auth/:provider/start", AuthController, :start
    delete "/logout", AuthController, :logout
  end

  # Per-tenant agent pages (require an agent session)
  scope "/t/:tenant_slug", FlorinaWeb do
    pipe_through [:browser, :resolve_tenant, :tenant_session, :agent_auth]
    live "/calls", CallsLive
    live "/chat", TenantChatLive
    live "/calendar", CalendarLive
    live "/today", AgentTodayLive
    live "/clients", ClientsLive

    # Manager-only screens (each LiveView gates with AgentAuth :require_manager).
    live "/manage/dashboard", Manage.DashboardLive
    live "/manage/meetings", Manage.MeetingsLive
    live "/manage/meetings/new", Manage.MeetingFormLive, :new
    live "/manage/meetings/:id", Manage.MeetingLive
    live "/manage/meetings/:id/edit", Manage.MeetingFormLive, :edit
    live "/manage/calls", Manage.CallsLive
    live "/manage/clients", Manage.ClientsLive
    live "/manage/clients/new", Manage.ClientLive, :new
    live "/manage/clients/:id", Manage.ClientLive, :edit
    live "/manage/agents", Manage.AgentsLive
    live "/manage/methodologies", Manage.MethodologiesLive
    live "/manage/mega-prompts", Manage.MegaPromptsLive
    live "/manage/generation-runs", Manage.GenerationRunsLive, :index
    live "/manage/generation-runs/:id", Manage.GenerationRunsLive, :show
    live "/manage/settings", Manage.SettingsLive
    live "/manage/logs", Manage.LogsLive
  end

  # Admin login / logout — browser only, no auth gate (these ARE the gate)
  scope "/admin", FlorinaWeb.Admin do
    pipe_through [:browser]
    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete
  end

  # Protected operator admin area — requires a valid admin session
  scope "/admin", FlorinaWeb.Admin do
    pipe_through [:browser, :require_admin]
    live "/", IndexLive
    live "/tenants", TenantsLive
    live "/tenants/:tenant_slug/agents", AgentsLive
    live "/config", ConfigLive
  end

  # Liveness probe for deploy checks and uptime monitors. Intentionally no
  # pipeline, so probes are cheap and unaffected by session/CSRF handling.
  scope "/", FlorinaWeb do
    get "/healthz", HealthController, :index
  end

  # Other scopes may use custom stacks.
  # scope "/api", FlorinaWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:florina, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: FlorinaWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end

    # UI component preview (dev only) — eyeball shells/components without auth.
    scope "/dev", FlorinaWeb do
      pipe_through :browser

      get "/shell", PageController, :shell_preview
    end
  end
end

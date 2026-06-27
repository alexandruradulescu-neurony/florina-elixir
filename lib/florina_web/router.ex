defmodule FlorinaWeb.Router do
  use FlorinaWeb, :router

  import FlorinaWeb.AgentAuth, only: [fetch_current_agent: 2, require_authenticated_agent: 2]

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FlorinaWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :webhook do
    plug :accepts, ["json"]
  end

  pipeline :dashboard_auth do
    plug :basic_auth_dashboard
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

  defp basic_auth_dashboard(conn, _opts) do
    creds = Application.fetch_env!(:florina, :dashboard_auth)
    Plug.BasicAuth.basic_auth(conn, username: creds[:username], password: creds[:password])
  end

  scope "/t/:tenant_slug/webhooks", FlorinaWeb.Webhook do
    pipe_through [:webhook, :resolve_tenant]
    post "/elevenlabs", ElevenLabsController, :create
  end

  scope "/", FlorinaWeb do
    pipe_through :browser

    get "/", PageController, :home

    # OAuth callback — fixed path (no tenant slug, so ONE redirect URI per provider
    # is registered with Google/Microsoft). The tenant is recovered from the signed
    # `state`; AuthController.callback resolves + pins it.
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
    live "/manage/meetings/:id", Manage.MeetingLive
    live "/manage/calls", Manage.CallsLive
    live "/manage/clients", Manage.ClientsLive
    live "/manage/clients/new", Manage.ClientLive, :new
    live "/manage/clients/:id", Manage.ClientLive, :edit
    live "/manage/agents", Manage.AgentsLive
    live "/manage/methodologies", Manage.MethodologiesLive
    live "/manage/prompts", Manage.PromptsLive
    live "/manage/mega-prompts", Manage.MegaPromptsLive
    live "/manage/generation-runs", Manage.GenerationRunsLive, :index
    live "/manage/generation-runs/:id", Manage.GenerationRunsLive, :show
    live "/manage/settings", Manage.SettingsLive
    live "/manage/logs", Manage.LogsLive
  end

  scope "/", FlorinaWeb do
    pipe_through [:browser, :dashboard_auth]
    live "/chat", ChatLive
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

defmodule FlorinaWeb.Router do
  use FlorinaWeb, :router

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

  pipeline :resolve_tenant do
    plug FlorinaWeb.Plugs.ResolveTenant
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

  scope "/webhooks", FlorinaWeb.Webhook do
    pipe_through [:webhook, :resolve_tenant]
    post "/elevenlabs", ElevenLabsController, :create
  end

  scope "/", FlorinaWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/", FlorinaWeb do
    pipe_through [:browser, :dashboard_auth, :resolve_tenant, :tenant_session]
    live "/calls", CallsLive
  end

  scope "/", FlorinaWeb do
    pipe_through [:browser, :dashboard_auth]
    live "/chat", ChatLive
  end

  scope "/", FlorinaWeb do
    pipe_through [:browser, :resolve_tenant]
    get "/whoami", WhoamiController, :show
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
  end
end

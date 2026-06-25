# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :florina,
  ecto_repos: [Florina.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure Oban (database-backed background jobs).
config :florina, Oban,
  repo: Florina.Repo,
  queues: [
    default: 10,
    # Fan-out cron schedulers (lightweight, high-priority)
    scheduler: 5,
    # Outbound call workers (rate-limited)
    calls: 5,
    # Sync jobs (calendar + CRM + call status polling)
    sync: 10,
    # Tenant provisioning (creates databases; intentionally low concurrency)
    provisioning: 2
  ],
  plugins: [
    # Periodically delete jobs that finished more than 7 days ago.
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},

    # Recurring cron jobs.
    # Cron fan-out pattern: each scheduler enqueues per-tenant child jobs.
    #
    # Schedule     Worker
    # ──────────── ──────────────────────────────────────────────────────────
    # Every 5 min  CallScheduler → ScanTenantCalls → DialCall
    # Every 15 min SyncPendingCallsScheduler → SyncPendingCalls
    # Every 30 min CalendarSyncScheduler → CalendarSync (per-user)
    # Daily 00:05  CrmSyncScheduler → CrmSync
    {Oban.Plugins.Cron,
     crontab: [
       {"*/5 * * * *", Florina.Workers.CallScheduler},
       {"*/15 * * * *", Florina.Workers.SyncPendingCallsScheduler},
       {"*/30 * * * *", Florina.Workers.CalendarSyncScheduler},
       {"5 0 * * *", Florina.Workers.CrmSyncScheduler}
     ]}
  ]

# Configure the endpoint
config :florina, FlorinaWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FlorinaWeb.ErrorHTML, json: FlorinaWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Florina.PubSub,
  live_view: [signing_salt: "THJzat0O"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :florina, Florina.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  florina: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  florina: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :florina, :dashboard_auth, username: "admin", password: "change-me-in-prod"

# Tenancy: one shared database + one connection pool (Florina.Repo). Each tenant
# is isolated by Postgres schema (`tenant_<id>`), provisioned + migrated via
# Florina.Tenants.Provisioner / Migrator with an Ecto `:prefix`. No per-tenant
# database or pool — so no pool-size / database-provisioner config.

# Auto-apply pending per-tenant migrations at app boot. Off by default (dev/test
# migrate explicitly / via TenantCase); turned on in prod (runtime.exs).
config :florina, :migrate_tenants_on_boot, false

config :florina,
  anthropic_model: "claude-sonnet-4-6",
  anthropic_client: Florina.Anthropic

# External integration clients (real impls; overridden to stubs in test.exs)
config :florina,
  elevenlabs_client: Florina.Integrations.ElevenLabs,
  oauth_provider_google: Florina.Integrations.Providers.Google,
  oauth_provider_microsoft: Florina.Integrations.Providers.Microsoft,
  pipedrive_client: Florina.Integrations.Pipedrive

# ElevenLabs — global keys (set in runtime.exs for prod from env)
config :florina,
  elevenlabs_api_key: nil,
  elevenlabs_agent_id: nil,
  elevenlabs_phone_number_id: nil

# Google Calendar OAuth — global client credentials (set in runtime.exs for prod)
config :florina,
  google_client_id: nil,
  google_client_secret: nil

# Microsoft (Entra ID) OAuth — global client credentials (set in runtime.exs for prod).
# Default audience is "organizations" (work/school accounts only) — personal
# Microsoft accounts are excluded, so the email/UPN used by the sign-in gate is
# always an org-controlled (DNS-verified) address. Override via MICROSOFT_TENANT.
config :florina,
  microsoft_client_id: nil,
  microsoft_client_secret: nil,
  microsoft_tenant: "organizations"

# Pipedrive — global keys (set in runtime.exs for prod from env)
config :florina,
  pipedrive_api_token: nil,
  pipedrive_domain: nil

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

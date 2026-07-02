import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/florina start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :florina, FlorinaWeb.Endpoint, server: true
end

config :florina, FlorinaWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  field_encryption_key =
    System.get_env("FIELD_ENCRYPTION_KEY") ||
      raise """
      environment variable FIELD_ENCRYPTION_KEY is missing.
      Generate one with: :crypto.strong_rand_bytes(32) |> Base.encode64()
      then set it in your deployment environment (e.g. Railway).
      """

  vault_key = Base.decode64!(field_encryption_key)

  # AES-256-GCM needs a 32-byte key; a wrong-length one boots fine then raises on
  # the FIRST encrypt/decrypt (every sign-in / settings save). Fail loud at boot.
  byte_size(vault_key) == 32 ||
    raise "FIELD_ENCRYPTION_KEY must decode (base64) to exactly 32 bytes, got #{byte_size(vault_key)}."

  config :florina, Florina.Vault,
    ciphers: [
      default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: vault_key, iv_length: 12}
    ]

  # Required: prompt generation, post-call lessons, and chat all depend on it.
  # Fail loud at boot (like the other required secrets) rather than degrading
  # silently at call time and retry-storming Oban jobs.
  config :florina,
         :anthropic_api_key,
         System.get_env("ANTHROPIC_API_KEY") ||
           raise("environment variable ANTHROPIC_API_KEY is missing.")

  # Apply pending per-tenant migrations automatically on boot (see application.ex)
  # so deploys that add tenant migrations don't need a manual migrate_tenants rpc.
  config :florina, :migrate_tenants_on_boot, true

  # Client document uploads live on the mounted persistent volume (Railway `/data`).
  # Must be a writable path that survives redeploys — a plain container path would
  # lose every uploaded file on the next deploy.
  config :florina, :uploads_root, System.get_env("UPLOADS_ROOT") || "/data"

  # ElevenLabs voice config (API key, agent id, phone-number id, webhook secret,
  # tools secret) is per-tenant — entered per workspace in Settings, NOT via env.
  # There is no global fallback: a tenant's voice features work only once its own
  # ElevenLabs settings are filled in.

  # Google Calendar OAuth app credentials
  config :florina,
    google_client_id: System.get_env("GOOGLE_CLIENT_ID"),
    google_client_secret: System.get_env("GOOGLE_CLIENT_SECRET")

  config :florina,
    microsoft_client_id: System.get_env("MICROSOFT_CLIENT_ID"),
    microsoft_client_secret: System.get_env("MICROSOFT_CLIENT_SECRET"),
    microsoft_tenant: System.get_env("MICROSOFT_TENANT") || "organizations"

  # Shared OAuth callback base (falls back to PHX_HOST endpoint URL). Set if the
  # public callback host differs from PHX_HOST.
  if base = System.get_env("OAUTH_REDIRECT_BASE") do
    config :florina, :oauth_redirect_base, base
  end

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # Web pool. Background jobs run on a SEPARATE pool (Florina.JobsRepo, below), so
  # this sizing only needs to cover web traffic. Raise POOL_SIZE for higher web
  # throughput, bounded by your Postgres max_connections (web pool + jobs pool).
  config :florina, Florina.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "20"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # Dedicated background-job pool: SAME database, separate connection pool, so a
  # burst of Oban jobs can't starve the web tier's connections. Oban and worker
  # tenant-queries (via TenantRepo, pinned in Workers.Tenant) use this pool.
  #
  # SIZING: must exceed the SUM of Oban queue concurrencies (config.exs, currently
  # 18) plus a few connections for Oban's own notifier/cron/pruner — otherwise
  # jobs contend for connections and retry-storm. Default 20 covers that.
  #
  # CONNECTION BUDGET (Postgres max_connections, currently 100): at deploy cutover
  # the OLD and NEW app containers briefly overlap — peak ≈
  # 2 × (POOL_SIZE + JOBS_POOL_SIZE). The pre-deploy migrate node runs BEFORE the
  # new container starts, so it doesn't stack on top of both. At defaults:
  # 2 × (20 + 20) = 80, leaving ~20 headroom under 100. Raise POOL_SIZE/
  # JOBS_POOL_SIZE together ONLY within that ceiling (or move to a bigger DB plan
  # / a pooler like PgBouncer to go higher).
  config :florina, Florina.JobsRepo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("JOBS_POOL_SIZE") || "20"),
    socket_options: maybe_ipv6

  config :florina, :jobs_repo, Florina.JobsRepo
  # Point Oban at the jobs pool (merges with the queues/plugins from config.exs).
  config :florina, Oban, repo: Florina.JobsRepo

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :florina, :tenant_base_host, System.get_env("TENANT_BASE_HOST") || host

  config :florina, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :florina, FlorinaWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :florina, FlorinaWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :florina, FlorinaWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :florina, Florina.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end

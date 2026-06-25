import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :florina, Florina.Repo,
  username: "alex",
  password: "",
  hostname: "localhost",
  database: "florina_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :florina, FlorinaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "HVBXqZRga39rJMczxa86sDjbLqqCIadXet54jnJcgvo+5cA2B4KwBJDYqi495cHd",
  server: false

# In test we don't send emails
config :florina, Florina.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Oban: don't run jobs automatically during tests; insert and assert/drain manually.
config :florina, Oban, testing: :manual

config :florina, :elevenlabs_webhook_secret, "wsec_test"

config :florina, :dashboard_auth, username: "admin", password: "test-pass"

config :florina, :anthropic_client, Florina.Anthropic.Stub
config :florina, :anthropic_api_key, "test-key"

# External integration stubs — no real HTTP calls in tests
config :florina,
  elevenlabs_client: Florina.Integrations.ElevenLabs.Stub,
  google_calendar_client: Florina.Integrations.GoogleCalendar.Stub,
  pipedrive_client: Florina.Integrations.Pipedrive.Stub

# Placeholder keys — ensure config keys exist (stubs don't use them)
config :florina,
  elevenlabs_api_key: nil,
  elevenlabs_agent_id: nil,
  elevenlabs_phone_number_id: nil,
  google_client_id: nil,
  google_client_secret: nil,
  pipedrive_api_token: nil,
  pipedrive_domain: nil

config :florina, :tenant_base_host, "localhost"

# Field-level encryption (Cloak). Fixed test key — NOT used in production.
config :florina, Florina.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1",
       key: Base.decode64!("KGQMP7DDM19f9+/66Cox8ER8pOfEEthN1czT+iNTmHE="),
       iv_length: 12}
  ]

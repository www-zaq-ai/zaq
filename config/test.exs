import Config

e2e? = System.get_env("E2E") == "1"
test_partition = System.get_env("MIX_TEST_PARTITION", "")

test_database =
  if e2e? do
    "zaq_test_e2e#{test_partition}"
  else
    "zaq_test#{test_partition}"
  end

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :zaq, Zaq.Repo,
  types: Zaq.PostgrexTypes,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: test_database,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :zaq, Oban,
  repo: Zaq.Repo,
  testing: :inline

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :zaq, ZaqWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "ciF/5ckzC38nrulQi0vIRpenNCD4oSsnLdBCLJhfXQmaRz0e6/iD9T15avsW/pV8",
  server: e2e?

config :zaq, Zaq.Embedding.Client,
  dimension: 1536,
  req_options: [plug: {Req.Test, Zaq.Embedding.Client}]

# --MOX--
config :zaq,
  chunk_title_module: Zaq.Agent.ChunkTitleMock,
  document_processor: Zaq.DocumentProcessorMock,
  node_router: Zaq.NodeRouterMock

config :zaq, Zaq.System.SecretConfig,
  encryption_key: "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=",
  key_id: "test-v1"

config :zaq, roles: [:bo, :ingestion, :agent, :channels, :engine]

config :zaq,
  license_runtime_key: true,
  skip_super_admin_seed: true,
  title_generation_enabled: false

# In test we don't send emails
config :zaq, Zaq.Mailer, adapter: Swoosh.Adapters.Test

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

# E2E observability routes and log collector are always available in test env
config :zaq, e2e: true

if e2e? do
  config :zaq, Zaq.Repo,
    pool: DBConnection.ConnectionPool,
    pool_size: 10

  config :zaq,
    node_router: Zaq.NodeRouter,
    document_processor: Zaq.E2E.DocumentProcessorFake,
    chat_live_node_router_module: Zaq.E2E.PlaygroundNodeRouterFake

  config :zaq, Zaq.Ingestion, base_path: "tmp/e2e_documents"
  config :zaq, e2e_routes: true
end

import Config

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
  database: "zaq_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :zaq, ZaqWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "ciF/5ckzC38nrulQi0vIRpenNCD4oSsnLdBCLJhfXQmaRz0e6/iD9T15avsW/pV8",
  server: false

config :zaq, Zaq.Embedding.Client,
  endpoint: "http://localhost",
  api_key: "",
  model: "test-model",
  dimension: 1536,
  req_options: [plug: {Req.Test, Zaq.Embedding.Client}]

config :zaq, roles: [:bo]

config :zaq,
  license_runtime_key: true,
  skip_super_admin_seed: true

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

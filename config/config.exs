# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :zaq,
  ecto_repos: [Zaq.Repo],
  generators: [timestamp_type: :utc_datetime]

config :mime, :types, %{
  "application/vnd.zaq-license" => ["zaq-license"]
}

config :zaq, Oban,
  repo: Zaq.Repo,
  queues: [
    ingestion: 3,
    default: 10,
    conversations: 5,
    telemetry: 5,
    telemetry_remote: 3,
    notifications: 5
  ],
  crontab: [],
  plugins: [
    {Zaq.Oban.DynamicCron,
     crontab: [
       {"* * * * *", Zaq.Engine.Telemetry.Workers.AggregateRollupsWorker},
       {"*/10 * * * *", Zaq.Engine.Telemetry.Workers.PushRollupsWorker},
       {"*/10 * * * *", Zaq.Engine.Telemetry.Workers.PullBenchmarksWorker},
       {"0 * * * *", Zaq.Engine.Telemetry.Workers.PrunePointsWorker}
     ]}
  ]

# Configure the endpoint
config :zaq, ZaqWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ZaqWeb.ErrorHTML, json: ZaqWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Zaq.PubSub,
  live_view: [signing_salt: "4Hg9E83u"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :zaq, Zaq.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  zaq: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :license_manager, :repo, Zaq.Repo

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  zaq: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

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
#     PHX_SERVER=true bin/zaq start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :zaq, ZaqWeb.Endpoint, server: true
end

config :zaq, ZaqWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  # SMTP password encryption (used by BO System Configuration page)
  # - SYSTEM_CONFIG_ENCRYPTION_KEY is required to save non-empty SMTP passwords
  # - key must represent exactly 32 bytes (raw 32-byte, base64-32-byte, or 64-char hex)
  # - SYSTEM_CONFIG_ENCRYPTION_KEY_ID is metadata for key rotation (default: v1)
  config :zaq, Zaq.System.SecretConfig,
    encryption_key: System.get_env("SYSTEM_CONFIG_ENCRYPTION_KEY"),
    key_id: System.get_env("SYSTEM_CONFIG_ENCRYPTION_KEY_ID", "v1")

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :zaq, Zaq.Repo,
    # ssl: true,
    url: database_url,
    types: Zaq.PostgrexTypes,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

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
  base_url_scheme = System.get_env("BASE_URL_SCHEME", "https")
  config :zaq, :base_url, System.get_env("BASE_URL", "#{base_url_scheme}://#{host}")

  config :zaq, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :zaq, ZaqWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # -- Agent LLM --
  config :zaq, Zaq.Agent.LLM,
    endpoint: System.get_env("LLM_ENDPOINT", "http://localhost:11434/v1"),
    api_key: System.get_env("LLM_API_KEY", ""),
    model: System.get_env("LLM_MODEL", "llama-3.3-70b-instruct"),
    temperature: 0.0,
    top_p: 0.9,
    supports_logprobs: System.get_env("LLM_SUPPORTS_LOGPROBS", "true") == "true",
    supports_json_mode: System.get_env("LLM_SUPPORTS_JSON_MODE", "true") == "true"

  # -- Embedding --
  config :zaq, Zaq.Embedding.Client,
    endpoint: System.get_env("EMBEDDING_ENDPOINT", "http://localhost:11434/v1"),
    api_key: System.get_env("EMBEDDING_API_KEY", ""),
    model: System.get_env("EMBEDDING_MODEL", "bge-multilingual-gemma2"),
    dimension: String.to_integer(System.get_env("EMBEDDING_DIMENSION", "3584"))

  # -- Ingestion --
  ingestion_volumes_env = System.get_env("INGESTION_VOLUMES", "")
  ingestion_volumes_base = System.get_env("INGESTION_VOLUMES_BASE", "/zaq/volumes")

  ingestion_volumes =
    if ingestion_volumes_env != "" do
      ingestion_volumes_env
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Map.new(fn name -> {name, Path.join(ingestion_volumes_base, name)} end)
    else
      %{}
    end

  config :zaq, Zaq.Ingestion,
    max_context_window: String.to_integer(System.get_env("INGESTION_MAX_CONTEXT_WINDOW", "5000")),
    distance_threshold: String.to_float(System.get_env("INGESTION_DISTANCE_THRESHOLD", "0.75")),
    hybrid_search_limit: String.to_integer(System.get_env("INGESTION_HYBRID_SEARCH_LIMIT", "20")),
    chunk_min_tokens: String.to_integer(System.get_env("INGESTION_CHUNK_MIN_TOKENS", "400")),
    chunk_max_tokens: String.to_integer(System.get_env("INGESTION_CHUNK_MAX_TOKENS", "900")),
    base_path: System.get_env("INGESTION_BASE_PATH", "/zaq/volumes/documents"),
    volumes: ingestion_volumes

  # -- Image to Text (Scaleway Pixtral) --
  config :zaq, Zaq.Ingestion.Python.ImageToText,
    api_url: System.get_env("IMAGE_TO_TEXT_API_URL", "http://localhost:11434/v1"),
    model: System.get_env("IMAGE_TO_TEXT_MODEL", "pixtral-12b-2409"),
    api_key: System.get_env("IMAGE_TO_TEXT_API_KEY", "")

  # -- Oban --
  config :zaq, Oban,
    repo: Zaq.Repo,
    queues: [
      ingestion: String.to_integer(System.get_env("OBAN_INGESTION_CONCURRENCY", "3")),
      conversations: String.to_integer(System.get_env("OBAN_CONVERSATIONS_CONCURRENCY", "5")),
      telemetry: String.to_integer(System.get_env("OBAN_TELEMETRY_CONCURRENCY", "5")),
      telemetry_remote:
        String.to_integer(System.get_env("OBAN_TELEMETRY_REMOTE_CONCURRENCY", "3")),
      default: 10
    ],
    plugins: [
      {Zaq.Oban.DynamicCron,
       crontab: [
         {"* * * * *", Zaq.Engine.Telemetry.Workers.AggregateRollupsWorker},
         {"*/10 * * * *", Zaq.Engine.Telemetry.Workers.PushRollupsWorker},
         {"*/10 * * * *", Zaq.Engine.Telemetry.Workers.PullBenchmarksWorker},
         {"0 * * * *", Zaq.Engine.Telemetry.Workers.PrunePointsWorker}
       ]}
    ],
    crontab: []

  # -- Knowledge Gap (paid feature, wiring) --
  config :zaq,
    sme_channel_id: System.get_env("SME_CHANNEL_ID", "barndiimztra5dg66x51dk7s9h"),
    knowledge_gap_immediate_threshold:
      String.to_integer(System.get_env("KNOWLEDGE_GAP_IMMEDIATE_THRESHOLD", "3")),
    default_business_id: System.get_env("DEFAULT_BUSINESS_ID")

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :zaq, ZaqWeb.Endpoint,
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
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :zaq, ZaqWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :zaq, Zaq.Mailer,
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
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end

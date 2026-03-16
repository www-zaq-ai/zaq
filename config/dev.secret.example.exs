import Config

config :zaq, :super_admin,
  username: "admin",
  password: "admin"

# -- Agent LLM --
config :zaq, Zaq.Agent.LLM,
  endpoint: "http://localhost:11434/v1",
  api_key: "",
  model: "llama3.2:latest",
  temperature: 0.0,
  top_p: 0.9,
  supports_logprobs: "true" == "true",
  supports_json_mode: "true" == "true"

# -- Embedding --
config :zaq, Zaq.Embedding.Client,
  endpoint: "http://localhost:11434/v1",
  api_key: "",
  model: "nomic-embed-text:latest",
  dimension: String.to_integer("768")

# -- Ingestion --
config :zaq, Zaq.Ingestion,
  max_context_window: String.to_integer("5000"),
  distance_threshold: String.to_float("0.75"),
  hybrid_search_limit: String.to_integer("20"),
  chunk_min_tokens: String.to_integer("400"),
  chunk_max_tokens: String.to_integer("900"),
  base_path: "priv/documents"

# -- Image to Text (Scaleway Pixtral) --
config :zaq, Zaq.Ingestion.Python.ImageToText,
  api_url: System.get_env("SCALEWAY_API_URL", "https://api.scaleway.ai/v1/chat/completions"),
  model: System.get_env("SCALEWAY_MODEL", "pixtral-12b-2409"),
  api_key: System.get_env("SCALEWAY_API_KEY", "")

config :zaq,
  sme_channel_id: System.get_env("SME_CHANNEL_ID", ""),
  knowledge_gap_immediate_threshold:
    String.to_integer(System.get_env("KNOWLEDGE_GAP_IMMEDIATE_THRESHOLD", "3")),
  default_business_id: System.get_env("DEFAULT_BUSINESS_ID")

# -- Notifications (SMTP) --
# In dev, emails are stored locally and viewable at http://localhost:4000/dev/mailbox.
# To test with a real SMTP server instead, uncomment and fill in the block below,
# then also set the mailer adapter:
#
# config :zaq, Zaq.Mailer,
#   adapter: Swoosh.Adapters.SMTP,
#   relay: "smtp.example.com",       # SMTP_RELAY
#   port: 587,                        # SMTP_PORT (default 587)
#   username: "you@example.com",      # SMTP_USERNAME
#   password: "your-smtp-password",   # SMTP_PASSWORD
#   tls: :enabled,                    # SMTP_TLS: enabled | always | never
#   auth: :always
#
# config :zaq, Zaq.Engine.Notifications,
#   from_email: "noreply@example.com",  # SMTP_FROM_EMAIL
#   from_name: "ZAQ"                    # SMTP_FROM_NAME
#
# Override the base URL used in password-reset links (default: http://localhost:4000):
# config :zaq, :base_url, "http://localhost:4000"

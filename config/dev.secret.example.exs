import Config

config :zaq, :super_admin,
  username: "admin",
  password: "admin"


config :zaq,
  sme_channel_id: System.get_env("SME_CHANNEL_ID", ""),
  knowledge_gap_immediate_threshold:
    String.to_integer(System.get_env("KNOWLEDGE_GAP_IMMEDIATE_THRESHOLD", "2")),
  default_business_id: System.get_env("DEFAULT_BUSINESS_ID")

# -- Notifications (SMTP) --
# Email is now configured from the back office UI at /bo/system-config.
# No environment variables are needed. In dev, emails are stored locally
# and viewable at http://localhost:4000/dev/mailbox.

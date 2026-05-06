# lib/zaq_web/router.ex

defmodule ZaqWeb.Router do
  use ZaqWeb, :router

  import JidoStudio.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ZaqWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :bo_auth do
    plug ZaqWeb.Plugs.Auth
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_stream do
    plug :fetch_query_params
  end

  scope "/", ZaqWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/s/:token", Live.SharedConversationLive
  end

  scope "/api", ZaqWeb do
    pipe_through :api

    post "/ask", AgentController, :ask
    post "/ingest", AgentController, :ingest
  end

  # BO - Public
  scope "/bo", ZaqWeb do
    pipe_through :browser

    live "/login", Live.BO.LoginLive
    live "/forgot-password", Live.BO.System.ForgotPasswordLive
    live "/reset-password/:token", Live.BO.System.ResetPasswordLive
    post "/session", BOSessionController, :create
    delete "/session", BOSessionController, :delete
  end

  # BO - Protected
  scope "/bo", ZaqWeb do
    pipe_through [:browser, :bo_auth]

    # File serving — raw content with correct Content-Type (opens in browser tab)
    get "/files/*path", FileController, :show

    live_session :bo, on_mount: {ZaqWeb.Live.BO.AuthHook, :default} do
      live "/dashboard", Live.BO.DashboardLive
      live "/dashboard/llm-performance", Live.BO.LLMPerformanceLive
      live "/dashboard/conversations-metrics", Live.BO.ConversationsMetricsLive
      live "/dashboard/knowledge-base-metrics", Live.BO.KnowledgeBaseMetricsLive
      live "/change-password", Live.BO.System.ChangePasswordLive
      live "/users", Live.BO.Accounts.UsersLive
      live "/users/new", Live.BO.Accounts.UserFormLive, :new
      live "/users/:id/edit", Live.BO.Accounts.UserFormLive, :edit
      live "/profile", Live.BO.Accounts.ProfileLive
      live "/roles", Live.BO.Accounts.RolesLive
      live "/roles/new", Live.BO.Accounts.RoleFormLive, :new
      live "/roles/:id/edit", Live.BO.Accounts.RoleFormLive, :edit
      live "/license", Live.BO.System.LicenseLive
      live "/system-config", Live.BO.System.SystemConfigLive
      live "/ai-diagnostics", Live.BO.AI.AIDiagnosticsLive
      live "/prompt-templates", Live.BO.AI.PromptTemplatesLive
      live "/agents", Live.BO.AI.AgentsLive
      live "/ingestion", Live.BO.AI.IngestionLive
      live "/ingestion/url_crawler/new", Live.BO.AI.UrlCrawlerSetupLive, :new
      live "/ingestion/url_crawler/preview/:id", Live.BO.AI.UrlCrawlerPreviewLive, :show
      live "/ingestion/url_crawler/:id/runs/:run_id", Live.BO.AI.UrlCrawlerRunDetailLive, :show
      live "/ingestion/url_crawler/:id", Live.BO.AI.UrlCrawlerDetailLive, :show
      live "/ontology", Live.BO.AI.OntologyLive
      live "/knowledge-gap", Live.BO.AI.KnowledgeGapLive

      # Channels — index (landing page with both sections)
      live "/channels", Live.BO.Communication.ChannelsIndexLive, :index

      # Email channel configuration
      live "/channels/retrieval/email", Live.BO.Communication.NotificationEmailLive, :index
      live "/channels/retrieval/email/smtp", Live.BO.Communication.NotificationSmtpLive, :index
      live "/channels/retrieval/email/imap", Live.BO.Communication.NotificationImapLive, :index

      # Retrieval channels — provider detail pages
      live "/channels/retrieval", Live.BO.Communication.ChannelsIndexLive, :retrieval
      live "/channels/retrieval/:provider", Live.BO.Communication.ChannelsLive, :retrieval

      # Ingestion channels — provider detail pages
      live "/channels/ingestion", Live.BO.Communication.ChannelsIndexLive, :ingestion
      live "/channels/ingestion/:provider", Live.BO.Communication.ChannelsLive, :ingestion

      live "/channels/notifications/logs", Live.BO.Communication.NotificationLogsLive

      # File preview — renders MD, plain text, images in-browser
      live "/preview/*path", Live.BO.AI.FilePreviewLive

      live "/chat", Live.BO.Communication.ChatLive
      live "/history", Live.BO.Communication.HistoryLive, :index
      live "/history/archived", Live.BO.Communication.HistoryLive, :archived

      live "/conversations/:id", Live.BO.Communication.ConversationDetailLive, :show

      live "/people", Live.BO.System.PeopleLive
    end

    jido_studio("/studio")
  end

  if Application.compile_env(:zaq, :e2e_routes, false) do
    scope "/e2e", ZaqWeb do
      pipe_through :api

      get "/processor/fail", E2EController, :fail
      get "/processor/reset", E2EController, :reset

      # Describe-level teardown and filesystem helpers. Documented in
      # docs/exec-plans/active/2026-04-20-fix-e2e-flakiness.md.
      post "/reset", E2EController, :reset_all
      post "/system-config", E2EController, :set_system_config
      post "/ingestion/touch_file", E2EController, :touch_file
    end

    scope "/e2e", ZaqWeb do
      pipe_through :api_stream

      post "/llm/v1/chat/completions", E2EController, :fake_llm
    end
  end

  if Application.compile_env(:zaq, :e2e, false) do
    scope "/e2e", ZaqWeb do
      pipe_through :api

      get "/health", E2EController, :health
      get "/telemetry/points", E2EController, :telemetry_points
      get "/logs/recent", E2EController, :logs_recent
    end
  end

  if Application.compile_env(:zaq, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ZaqWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end

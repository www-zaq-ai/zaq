# lib/zaq_web/router.ex

defmodule ZaqWeb.Router do
  use ZaqWeb, :router

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

  scope "/", ZaqWeb do
    pipe_through :browser

    get "/", PageController, :home
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
      live "/dashboard/telemetry-preview", Live.BO.TelemetryPreviewLive
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
      live "/ingestion", Live.BO.AI.IngestionLive
      live "/ontology", Live.BO.AI.OntologyLive
      live "/knowledge-gap", Live.BO.AI.KnowledgeGapLive

      # Channels — index (landing page with both sections)
      live "/channels", Live.BO.Communication.ChannelsIndexLive, :index

      # Retrieval channels — provider detail pages
      live "/channels/retrieval", Live.BO.Communication.ChannelsIndexLive, :retrieval
      live "/channels/retrieval/:provider", Live.BO.Communication.ChannelsLive, :retrieval

      # Ingestion channels — provider detail pages
      live "/channels/ingestion", Live.BO.Communication.ChannelsIndexLive, :ingestion
      live "/channels/ingestion/:provider", Live.BO.Communication.ChannelsLive, :ingestion

      # Notification channels
      live "/channels/notifications", Live.BO.Communication.ChannelsIndexLive, :notification
      live "/channels/notifications/email", Live.BO.Communication.NotificationEmailLive, :index

      live "/channels/notifications/email/:type",
           Live.BO.Communication.NotificationSmtpLive,
           :index

      live "/notification-logs", Live.BO.Communication.NotificationLogsLive

      # File preview — renders MD, plain text, images in-browser
      live "/preview/*path", Live.BO.AI.FilePreviewLive

      live "/chat", Live.BO.Communication.ChatLive
      live "/history", Live.BO.Communication.HistoryLive

      live "/conversations/:id", Live.BO.Communication.ConversationDetailLive, :show
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

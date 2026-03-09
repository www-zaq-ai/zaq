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
    post "/pending-questions", PendingQuestionsController, :create
  end

  # BO - Public
  scope "/bo", ZaqWeb do
    pipe_through :browser

    live "/login", Live.BO.LoginLive
    post "/session", BOSessionController, :create
    delete "/session", BOSessionController, :delete
  end

  # BO - Protected
  scope "/bo", ZaqWeb do
    pipe_through [:browser, :bo_auth]

    live_session :bo, on_mount: {ZaqWeb.Live.BO.AuthHook, :default} do
      live "/dashboard", Live.BO.DashboardLive
      live "/change-password", Live.Bo.System.ChangePasswordLive
      live "/users", Live.BO.Accounts.UsersLive
      live "/users/new", Live.BO.Accounts.UserFormLive, :new
      live "/users/:id/edit", Live.BO.Accounts.UserFormLive, :edit
      live "/roles", Live.BO.Accounts.RolesLive
      live "/roles/new", Live.BO.Accounts.RoleFormLive, :new
      live "/roles/:id/edit", Live.BO.Accounts.RoleFormLive, :edit
      live "/license", Live.Bo.System.LicenseLive
      live "/ai-diagnostics", Live.BO.AI.AIDiagnosticsLive
      live "/prompt-templates", Live.BO.AI.PromptTemplatesLive
      live "/ingestion", Live.BO.AI.IngestionLive
      live "/ontology", Live.BO.AI.OntologyLive
      live "/widget-settings", Live.BO.Widget.SettingsLive
      live "/channels", Live.BO.Communication.ChannelsLive
      live "/playground", Live.BO.Communication.PlaygroundLive
      live "/history", Live.BO.Communication.HistoryLive
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

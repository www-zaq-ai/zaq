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

    live "/dashboard", Live.BO.DashboardLive
    live "/change-password", Live.BO.ChangePasswordLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", ZaqWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:zaq, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ZaqWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end

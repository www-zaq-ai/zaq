defmodule ZaqWeb.Plugs.Auth do
  @moduledoc """
  Authenticates requests by loading the current user from the session.

  Redirects to the login page when no session is present, and to the
  password-change page when `must_change_password` is set on the user.
  """
  import Plug.Conn
  import Phoenix.Controller

  use Phoenix.VerifiedRoutes,
    endpoint: ZaqWeb.Endpoint,
    router: ZaqWeb.Router,
    statics: ZaqWeb.static_paths()

  alias Zaq.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, :user_id) do
      nil ->
        conn
        |> put_flash(:error, "You must log in to access this page.")
        |> redirect(to: ~p"/bo/login")
        |> halt()

      user_id ->
        user = Accounts.get_user!(user_id)

        if user.must_change_password and conn.request_path != ~p"/bo/change-password" do
          conn
          |> redirect(to: ~p"/bo/change-password")
          |> halt()
        else
          assign(conn, :current_user, user)
        end
    end
  end
end

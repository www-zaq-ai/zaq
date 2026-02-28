defmodule ZaqWeb.Plugs.Auth do
  @moduledoc """
  This plug is responsible for authenticating users based on the session.
  It checks if a user ID is present in the session, retrieves the corresponding user from the database, and assigns it to the connection. If no user ID is found, it redirects to the login page. Additionally, if the user has the `must_change_password` flag set to true, it redirects them to the change password page before allowing access to any other routes.
  """
  import Plug.Conn
  import Phoenix.Controller

  alias Zaq.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, :user_id) do
      nil ->
        conn
        |> put_flash(:error, "You must log in to access this page.")
        |> redirect(to: "/bo/login")
        |> halt()

      user_id ->
        user = Accounts.get_user!(user_id)

        if user.must_change_password and conn.request_path != "/bo/change-password" do
          conn
          |> redirect(to: "/bo/change-password")
          |> halt()
        else
          assign(conn, :current_user, user)
        end
    end
  end
end

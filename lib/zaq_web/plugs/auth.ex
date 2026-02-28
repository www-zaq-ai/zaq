# lib/zaq_web/plugs/auth.ex

defmodule ZaqWeb.Plugs.Auth do
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

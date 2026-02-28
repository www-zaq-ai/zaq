defmodule ZaqWeb.BOSessionController do
  use ZaqWeb, :controller

  alias Zaq.Accounts

  def create(conn, %{"username" => username, "password" => password}) do
    case Accounts.authenticate_user(username, password) do
      {:ok, %{must_change_password: true} = user} ->
        conn
        |> put_session(:user_id, user.id)
        |> redirect(to: ~p"/bo/change-password")

      {:ok, user} ->
        conn
        |> put_session(:user_id, user.id)
        |> redirect(to: ~p"/bo/dashboard")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Invalid username or password")
        |> redirect(to: ~p"/bo/login")
    end
  end

  def delete(conn, _params) do
    conn
    |> clear_session()
    |> redirect(to: ~p"/bo/login")
  end
end

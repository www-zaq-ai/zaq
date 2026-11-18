defmodule ZaqWeb.BOSessionController do
  use ZaqWeb, :controller

  alias Zaq.Accounts
  alias ZaqWeb.BOSession

  def create(conn, %{"username" => username, "password" => password}) do
    case Accounts.authenticate_user(username, password) do
      {:ok, %{must_change_password: true} = user} ->
        conn
        |> BOSession.sign_in(user)
        |> redirect(to: ~p"/bo/change-password")

      {:ok, user} ->
        conn
        |> BOSession.sign_in(user)
        |> redirect(to: ~p"/bo/dashboard")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Invalid username or password")
        |> redirect(to: ~p"/bo/login")
    end
  end

  def bootstrap_login(conn, _params) do
    case Accounts.bootstrap_admin_pending_onboarding() do
      %{must_change_password: true} = user ->
        conn
        |> BOSession.sign_in(user)
        |> redirect(to: ~p"/bo/change-password")

      _ ->
        conn
        |> put_flash(:error, "Invalid username or password")
        |> redirect(to: ~p"/bo/login")
    end
  end

  def delete(conn, _params) do
    conn
    |> delete_session(:user_id)
    |> delete_session(:bo_session_nonce)
    |> delete_session(:bootstrap_browser)
    |> redirect(to: ~p"/bo/login")
  end

  def complete_bootstrap(conn, %{"handoff_token" => token}) when is_binary(token) do
    case BOSession.finish_bootstrap(conn, token) do
      {:ok, conn, {:welcome, metadata}} ->
        conn
        |> put_flash(:bootstrap_welcome, metadata)
        |> redirect(to: ~p"/bo/change-password")

      {:ok, conn, {:dashboard, message}} ->
        conn |> put_flash(:info, message) |> redirect(to: ~p"/bo/dashboard")

      :error ->
        redirect(conn, to: ~p"/bo/login")
    end
  end

  def complete_bootstrap(conn, _params), do: redirect(conn, to: ~p"/bo/login")
end

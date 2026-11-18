defmodule ZaqWeb.BOSession do
  @moduledoc "Establishes and verifies Back Office sessions bound to an account."

  import Plug.Conn

  alias Zaq.Accounts

  @bootstrap_salt "back office bootstrap completion"
  @bootstrap_max_age 120

  def sign_in(conn, user) do
    conn
    |> configure_session(renew: true)
    |> put_session(:user_id, user.id)
    |> put_session(:bo_session_nonce, user.bo_session_nonce)
    |> delete_session(:bootstrap_browser)
  end

  def valid?(%{bo_session_nonce: expected}, actual), do: expected == actual
  def valid?(_, _), do: false

  @doc "Binds a pending setup page to the browser's signed session."
  def bind_bootstrap_browser(conn) do
    case get_session(conn, :bootstrap_browser) do
      nil ->
        put_session(conn, :bootstrap_browser, Base.url_encode64(:crypto.strong_rand_bytes(32)))

      _ ->
        conn
    end
  end

  @doc "Creates a short-lived handoff for the browser that committed registration."
  def bootstrap_handoff(user, browser, destination) when is_binary(browser) do
    Phoenix.Token.encrypt(
      ZaqWeb.Endpoint,
      @bootstrap_salt,
      {user.id, user.bo_session_nonce, browser, destination}
    )
  end

  @doc "Renews only the browser session bound to a completed bootstrap registration."
  def finish_bootstrap(conn, handoff_token) do
    with id when is_integer(id) <- get_session(conn, :user_id),
         browser when is_binary(browser) <- get_session(conn, :bootstrap_browser),
         {:ok, {^id, nonce, ^browser, destination}} when is_binary(nonce) <-
           Phoenix.Token.decrypt(conn, @bootstrap_salt, handoff_token,
             max_age: @bootstrap_max_age
           ),
         %{bo_session_nonce: ^nonce, must_change_password: false} = user <- Accounts.get_user(id),
         false <- valid?(user, get_session(conn, :bo_session_nonce)) do
      {:ok, sign_in(conn, user), destination}
    else
      _ -> :error
    end
  end
end

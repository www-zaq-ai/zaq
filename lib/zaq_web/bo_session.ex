defmodule ZaqWeb.BOSession do
  @moduledoc "Establishes and verifies Back Office sessions bound to an account."

  import Plug.Conn

  def sign_in(conn, user) do
    conn
    |> configure_session(renew: true)
    |> put_session(:user_id, user.id)
    |> put_session(:bo_session_nonce, user.bo_session_nonce)
  end

  def valid?(%{bo_session_nonce: expected}, actual), do: expected == actual
  def valid?(_, _), do: false
end

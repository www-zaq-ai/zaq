defmodule ZaqWeb.Plugs.ChatBearerAuth do
  @moduledoc false

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with expected when is_binary(expected) and expected != "" <-
           System.get_env("ZAQ_CHAT_TOKEN"),
         ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- Plug.Crypto.secure_compare(token, expected) do
      conn
    else
      nil -> reject(conn, 503, "chat transport not configured")
      "" -> reject(conn, 503, "chat transport not configured")
      [] -> reject(conn, 401, "missing bearer token")
      _ -> reject(conn, 403, "invalid bearer token")
    end
  end

  defp reject(conn, status, message) do
    body = Jason.encode!(%{error: %{message: message}})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end
end

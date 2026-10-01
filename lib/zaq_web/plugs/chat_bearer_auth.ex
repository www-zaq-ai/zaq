defmodule ZaqWeb.Plugs.ChatBearerAuth do
  @moduledoc """
  Authenticates the OpenAI-compatible API (`/v1/*`) with the shared
  `ZAQ_CHAT_TOKEN` bearer token, compared in constant time.

  Plugged in `ZaqWeb.Endpoint` before `Plug.Parsers`, so an unauthenticated
  request is rejected before its body is read. Fails closed: 503 while no
  token is configured.

  Options: `:path_prefixes`, the request path prefixes it protects.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    if protected_path?(conn, opts), do: authenticate(conn), else: conn
  end

  defp protected_path?(conn, opts) do
    Enum.any?(Keyword.fetch!(opts, :path_prefixes), fn prefix ->
      conn.request_path == prefix or String.starts_with?(conn.request_path, prefix <> "/")
    end)
  end

  defp authenticate(conn) do
    with expected when is_binary(expected) and expected != "" <-
           System.get_env("ZAQ_CHAT_TOKEN"),
         ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- Plug.Crypto.secure_compare(token, expected) do
      conn
    else
      nil -> reject(conn, 503, "chat transport not configured")
      "" -> reject(conn, 503, "chat transport not configured")
      [] -> reject(conn, 401, "missing bearer token")
      _ -> reject(conn, 401, "invalid bearer token")
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

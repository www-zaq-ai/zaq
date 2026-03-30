defmodule ZaqWeb.APIResponse do
  @moduledoc false

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn, only: [put_status: 2]

  @spec ok(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ok(conn, payload), do: json(conn, payload)

  @spec accepted(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def accepted(conn, payload), do: conn |> put_status(:accepted) |> json(payload)

  @spec error(Plug.Conn.t(), atom() | integer(), String.t() | map()) :: Plug.Conn.t()
  def error(conn, status, message) when is_binary(message) do
    conn |> put_status(status) |> json(%{error: message})
  end

  def error(conn, status, payload) when is_map(payload) do
    conn |> put_status(status) |> json(payload)
  end
end

defmodule ZaqWeb.Plugs.RequireAnyRole do
  @moduledoc """
  Restricts a scope to nodes that have at least one required role.

  Returns `404` when disallowed to avoid exposing route existence.
  """

  import Plug.Conn

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    required_roles = Keyword.fetch!(opts, :roles)

    if Zaq.NodeRoles.has_any?(required_roles) do
      conn
    else
      conn
      |> send_resp(:not_found, "Not Found")
      |> halt()
    end
  end
end

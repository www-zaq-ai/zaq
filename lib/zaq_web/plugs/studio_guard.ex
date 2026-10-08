defmodule ZaqWeb.Plugs.StudioGuard do
  @moduledoc """
  Blocks Studio HTTP routes unless an administrator has enabled its local runtime.
  Runs after BO authentication, before any Studio LiveView can lazily start storage.
  """

  import Plug.Conn
  import Phoenix.Controller

  alias ZaqWeb.StudioRuntime

  def init(opts), do: opts

  def call(conn, _opts) do
    if StudioRuntime.authorized?(conn.assigns.current_user) and StudioRuntime.running?() do
      conn
    else
      conn
      |> put_flash(
        :error,
        "Jido Studio requires an administrator to enable it in Telemetry settings."
      )
      |> redirect(to: "/bo/system-config?tab=telemetry")
      |> halt()
    end
  end
end

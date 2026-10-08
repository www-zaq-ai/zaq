defmodule ZaqWeb.Live.BO.StudioGuard do
  @moduledoc """
  Guards connected Studio mounts as well as HTTP mounts after BO authentication.
  """

  import Phoenix.LiveView, only: [redirect: 2]

  alias ZaqWeb.StudioRuntime

  def on_mount(:require_running, _params, _session, socket) do
    if StudioRuntime.authorized?(socket.assigns.current_user) and StudioRuntime.running?() do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/bo/system-config?tab=telemetry")}
    end
  end
end

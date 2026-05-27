defmodule ZaqWeb.Live.BO.WorkflowGuard do
  @moduledoc """
  `on_mount` hook that blocks access to workflow LiveViews when the
  workflows feature is disabled via the `WORKFLOWS_ENABLED` environment variable.
  Redirects to the dashboard when the feature is off.
  """
  use ZaqWeb, :verified_routes
  import Phoenix.LiveView

  def on_mount(:require_workflows, _params, _session, socket) do
    if Application.get_env(:zaq, :workflows_enabled, true) do
      {:cont, socket}
    else
      {:halt, push_navigate(socket, to: ~p"/bo/dashboard")}
    end
  end
end

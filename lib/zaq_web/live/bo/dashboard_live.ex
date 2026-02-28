# lib/zaq_web/live/bo/dashboard_live.ex

defmodule ZaqWeb.Live.BO.DashboardLive do
  use ZaqWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, socket}
  end
end

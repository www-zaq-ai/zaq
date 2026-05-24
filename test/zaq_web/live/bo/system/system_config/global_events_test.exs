defmodule ZaqWeb.Live.BO.System.SystemConfig.GlobalEventsTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias ZaqWeb.Live.BO.System.SystemConfig.GlobalEvents

  test "apply_default_agent_saved/2 assigns global agent id" do
    socket = %Socket{assigns: %{__changed__: %{}}}
    updated = GlobalEvents.apply_default_agent_saved(socket, 12)
    assert updated.assigns.global_default_agent_id == 12
  end

  test "apply_base_url_saved/2 normalizes nil to empty string" do
    socket = %Socket{assigns: %{__changed__: %{}}}
    updated = GlobalEvents.apply_base_url_saved(socket, nil)
    assert updated.assigns.global_base_url == ""
  end
end

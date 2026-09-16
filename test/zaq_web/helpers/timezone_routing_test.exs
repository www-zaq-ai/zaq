defmodule ZaqWeb.Helpers.TimezoneRoutingTest do
  use Zaq.DataCase, async: false
  alias Zaq.Event
  alias Zaq.System
  alias ZaqWeb.Helpers.Timezone

  test "default formatting reads and caches timezone through the existing Engine action" do
    previous = Application.fetch_env(:zaq, :system_timezone_fun)
    Application.delete_env(:zaq, :system_timezone_fun)
    Process.delete(:zaq_system_timezone)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:zaq, :system_timezone_fun, value)
        :error -> Application.delete_env(:zaq, :system_timezone_fun)
      end
    end)

    System.set_system_timezone("GMT+02:00")
    Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")
    assert Timezone.shift(~U[2026-09-15 12:00:00Z]) == ~N[2026-09-15 14:00:00]
    assert Timezone.shift(~N[2026-09-15 12:00:00]) == ~N[2026-09-15 14:00:00]

    assert_receive {:node_router_event,
                    %Event{
                      request: %{},
                      opts: [{:action, :system_config_get_system_timezone} | _]
                    }},
                   500

    System.set_system_timezone("GMT-01:00")
    assert Timezone.shift(~U[2026-09-15 12:00:00Z]) == ~N[2026-09-15 14:00:00]

    refute_receive {:node_router_event,
                    %Event{opts: [{:action, :system_config_get_system_timezone} | _]}}
  end
end

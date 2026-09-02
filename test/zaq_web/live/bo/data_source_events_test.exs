defmodule ZaqWeb.Live.BO.DataSourceEventsTest do
  use ExUnit.Case, async: true

  alias ZaqWeb.Live.BO.DataSourceEvents

  test "builds data-source channel event with a regular BO actor" do
    user = %{id: 1, person_id: 2, username: "regular"}

    event =
      DataSourceEvents.build(
        :data_source_list_files,
        %{provider: :google_drive, params: %{}},
        user,
        event_opts: [data_source_bridge_module: StubBridge]
      )

    assert event.next_hop.destination == :channels
    assert event.opts[:action] == :data_source_list_files
    assert event.opts[:data_source_bridge_module] == StubBridge
    refute Keyword.has_key?(event.opts, :skip_permissions)
    assert event.actor.person_id == 2
    assert event.actor.provider == "bo"
    assert event.actor.skip_permissions == false
  end

  test "projects super-admin bypass into trusted event options" do
    user = %{id: 1, person_id: 2, username: "root", role: %{name: "super_admin"}}

    event =
      DataSourceEvents.build(
        :data_source_list_files,
        %{provider: :google_drive, params: %{}},
        user
      )

    assert event.opts[:skip_permissions] == true
    assert event.actor.skip_permissions == true
  end
end

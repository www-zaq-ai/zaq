defmodule Zaq.Engine.PeopleAccessConfigApiTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Api
  alias Zaq.Engine.Events
  alias Zaq.System.PeopleAccessConfig

  test "Engine events route the group read and authoritative save" do
    event =
      Events.build_and_dispatch_invoke_event(%{}, :system_config_get_people_access_config,
        node_router: Zaq.NodeRouter
      )

    assert {:ok, %PeopleAccessConfig{session_lifetime_seconds: 604_800}} = event.response

    event =
      Events.build_and_dispatch_invoke_event(
        %{attrs: %{"otp_max_attempts" => "11"}},
        :system_config_save_people_access_config,
        node_router: Zaq.NodeRouter
      )

    assert {:ok, %PeopleAccessConfig{otp_max_attempts: 11}} = event.response
  end

  test "invalid attributes are validated by System even when bypassing the UI" do
    event =
      Events.build_invoke_event(
        %{attrs: %{otp_max_attempts: 1.0}},
        :system_config_save_people_access_config
      )

    assert %{response: {:error, %Ecto.Changeset{valid?: false}}} =
             Api.handle_event(event, :system_config_save_people_access_config, %{})
  end

  test "invalid envelope and unknown action keep the boundary error contract" do
    event =
      Events.build_invoke_event(
        %{changeset: Ecto.Changeset.change(%PeopleAccessConfig{})},
        :system_config_save_people_access_config
      )

    assert %{response: {:error, {:invalid_request, _}}} =
             Api.handle_event(event, :system_config_save_people_access_config, %{})

    assert %{response: {:error, _}} = Api.handle_event(event, :unknown_people_access_action, %{})
  end
end

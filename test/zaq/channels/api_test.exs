defmodule Zaq.Channels.ApiTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.Api
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event

  defmodule StubCommunicationBridge do
    def deliver(%Outgoing{} = outgoing) do
      send(self(), {:bridge_deliver, outgoing})
      :ok
    end

    def sync_config_runtime(before_config, after_config) do
      send(self(), {:bridge_sync_config_runtime, before_config, after_config})
      :ok
    end

    def sync_provider_runtime(provider) do
      send(self(), {:bridge_sync_provider_runtime, provider})
      :ok
    end
  end

  defmodule StubRouter do
    def test_connection(%ChannelConfig{} = config, channel_id) do
      send(self(), {:router_test_connection, config.id, channel_id})
      {:ok, %{id: "ok"}}
    end
  end

  test "handles deliver_outgoing action" do
    outgoing = %Outgoing{body: "ok", channel_id: "c1", provider: :web}

    event =
      Event.new(outgoing, :channels,
        opts: [action: :deliver_outgoing, communication_bridge_module: StubCommunicationBridge]
      )

    result = Api.handle_event(event, :deliver_outgoing, nil)

    assert result.response == :ok
    assert_received {:bridge_deliver, ^outgoing}
  end

  test "handles sync_channel_runtime action" do
    before_config = %{id: 1, enabled: true}
    after_config = %{id: 1, enabled: false}

    event =
      Event.new(%{before_config: before_config, after_config: after_config}, :channels,
        opts: [
          action: :sync_channel_runtime,
          communication_bridge_module: StubCommunicationBridge
        ]
      )

    result = Api.handle_event(event, :sync_channel_runtime, nil)

    assert result.response == :ok
    assert_received {:bridge_sync_config_runtime, ^before_config, ^after_config}
  end

  test "handles sync_provider_runtime action" do
    event =
      Event.new(%{provider: :mattermost}, :channels,
        opts: [
          action: :sync_provider_runtime,
          communication_bridge_module: StubCommunicationBridge
        ]
      )

    result = Api.handle_event(event, :sync_provider_runtime, nil)

    assert result.response == :ok
    assert_received {:bridge_sync_provider_runtime, :mattermost}
  end

  test "handles test_connection action" do
    config = %ChannelConfig{id: 42}
    channel_id = "chan-1"

    event =
      Event.new(%{config: config, channel_id: channel_id}, :channels,
        opts: [action: :test_connection, router_module: StubRouter]
      )

    result = Api.handle_event(event, :test_connection, nil)

    assert result.response == {:ok, %{id: "ok"}}
    assert_received {:router_test_connection, 42, "chan-1"}
  end

  test "delegates incoming_async_hop to shared helper" do
    event = Event.new(%{module: String, function: :upcase, args: ["hop"]}, :channels)

    result = Api.handle_event(event, :incoming_async_hop, nil)

    assert result.response == "HOP"
  end

  test "delegates invoke to shared helper" do
    event = Event.new(%{module: String, function: :upcase, args: ["hi"]}, :channels)

    result = Api.handle_event(event, :invoke, nil)

    assert result.response == "HI"
  end

  test "returns unsupported action when payload/action mismatch" do
    event = Event.new(%{bad: true}, :channels)

    result = Api.handle_event(event, :deliver_outgoing, nil)

    assert result.response == {:error, {:unsupported_action, :deliver_outgoing}}
  end
end

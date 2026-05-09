defmodule Zaq.Channels.ApiTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.Api
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event

  defmodule StubCommunicationBridge do
    def bridge_for(_provider), do: Zaq.Channels.ApiTest.StubBridgeImpl
    def fetch_connection_details(_provider), do: %{url: "https://example.test", token: "token"}
    def fetch_channel_config(_provider), do: {:ok, %{id: 1, provider: "mattermost"}}

    def sync_config_runtime(before_config, after_config) do
      send(self(), {:bridge_sync_config_runtime, before_config, after_config})
      :ok
    end

    def sync_provider_runtime(provider) do
      send(self(), {:bridge_sync_provider_runtime, provider})
      :ok
    end
  end

  defmodule StubCommunicationBridgeConfigError do
    def bridge_for(_provider), do: Zaq.Channels.ApiTest.StubBridgeImpl
    def fetch_connection_details(_provider), do: %{url: "https://example.test", token: "token"}
    def fetch_channel_config(_provider), do: {:error, :channel_not_configured}
  end

  defmodule StubBridgeImpl do
    def send_reply(%Outgoing{} = outgoing, details) do
      send(self(), {:bridge_send_reply, outgoing, details})
      :ok
    end

    def test_connection(%ChannelConfig{} = config, channel_id) do
      send(self(), {:bridge_test_connection, config.id, channel_id})
      {:ok, %{id: "ok"}}
    end

    def send_typing(config, channel_id, details) do
      send(self(), {:bridge_send_typing, config, channel_id, details})
      :ok
    end

    def fetch_profile(author_id, details) do
      send(self(), {:bridge_fetch_profile, author_id, details})
      {:ok, %{id: author_id}}
    end

    def open_dm_channel(author_id, details) do
      send(self(), {:bridge_open_dm_channel, author_id, details})
      {:ok, "dm-1"}
    end

    def list_mailboxes(config, details) do
      send(self(), {:bridge_list_mailboxes, config, details})
      {:ok, ["INBOX"]}
    end
  end

  defmodule StubBridgeNoCallbacks do
    def send_reply(%Outgoing{} = outgoing, details) do
      send(self(), {:bridge_send_reply, outgoing, details})
      :ok
    end
  end

  defmodule StubCommunicationBridgeNoCallbacks do
    def bridge_for(_provider), do: Zaq.Channels.ApiTest.StubBridgeNoCallbacks
    def fetch_connection_details(_provider), do: %{url: "https://example.test", token: "token"}
    def fetch_channel_config(_provider), do: {:ok, %{id: 1, provider: "mattermost"}}
  end

  defmodule StubCommunicationBridgeNoBridge do
    def bridge_for(_provider), do: nil
    def fetch_connection_details(_provider), do: %{url: "https://example.test", token: "token"}
    def fetch_channel_config(_provider), do: {:ok, %{id: 1, provider: "mattermost"}}
  end

  test "handles deliver_outgoing action" do
    outgoing = %Outgoing{body: "ok", channel_id: "c1", provider: :web}

    event =
      Event.new(outgoing, :channels,
        opts: [action: :deliver_outgoing, bridge_module: StubCommunicationBridge]
      )

    result = Api.handle_event(event, :deliver_outgoing, nil)

    assert result.response == :ok

    assert_received {:bridge_send_reply, ^outgoing,
                     %{url: "https://example.test", token: "token"}}
  end

  test "handles deliver_outgoing action when outgoing is in event response" do
    outgoing = %Outgoing{body: "ok", channel_id: "c1", provider: :web}

    event =
      Event.new(%{noop: true}, :channels,
        opts: [action: :deliver_outgoing, bridge_module: StubCommunicationBridge]
      )

    result = Api.handle_event(%{event | response: outgoing}, :deliver_outgoing, nil)

    assert result.response == :ok

    assert_received {:bridge_send_reply, ^outgoing,
                     %{url: "https://example.test", token: "token"}}
  end

  test "handles sync_channel_runtime action" do
    before_config = %{id: 1, enabled: true}
    after_config = %{id: 1, enabled: false}

    event =
      Event.new(%{before_config: before_config, after_config: after_config}, :channels,
        opts: [
          action: :sync_channel_runtime,
          runtime_module: StubCommunicationBridge
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
          runtime_module: StubCommunicationBridge
        ]
      )

    result = Api.handle_event(event, :sync_provider_runtime, nil)

    assert result.response == :ok
    assert_received {:bridge_sync_provider_runtime, :mattermost}
  end

  test "handles test_connection action" do
    config = %ChannelConfig{id: 42, provider: "mattermost"}
    channel_id = "chan-1"

    event =
      Event.new(%{config: config, channel_id: channel_id}, :channels,
        opts: [action: :test_connection, bridge_module: StubCommunicationBridge]
      )

    result = Api.handle_event(event, :test_connection, nil)

    assert result.response == {:ok, %{id: "ok"}}
    assert_received {:bridge_test_connection, 42, "chan-1"}
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

    assert result.response == {:error, {:invalid_request, :missing_outgoing_payload}}
  end

  test "send_typing returns config fetch errors" do
    event =
      Event.new(%{provider: :mattermost, channel_id: "chan-1"}, :channels,
        opts: [action: :send_typing, bridge_module: StubCommunicationBridgeConfigError]
      )

    result = Api.handle_event(event, :send_typing, nil)

    assert result.response == {:error, :channel_not_configured}
  end

  test "handles send_typing success" do
    event =
      Event.new(%{provider: :mattermost, channel_id: "chan-1"}, :channels,
        opts: [action: :send_typing, bridge_module: StubCommunicationBridge]
      )

    result = Api.handle_event(event, :send_typing, nil)

    assert result.response == :ok
    assert_received {:bridge_send_typing, %{id: 1, provider: "mattermost"}, "chan-1", _details}
  end

  test "send_typing returns unsupported when callback is missing" do
    event =
      Event.new(%{provider: :mattermost, channel_id: "chan-1"}, :channels,
        opts: [action: :send_typing, bridge_module: StubCommunicationBridgeNoCallbacks]
      )

    result = Api.handle_event(event, :send_typing, nil)
    assert result.response == {:error, :unsupported}
  end

  test "send_typing returns no_bridge when provider bridge is missing" do
    event =
      Event.new(%{provider: :mattermost, channel_id: "chan-1"}, :channels,
        opts: [action: :send_typing, bridge_module: StubCommunicationBridgeNoBridge]
      )

    result = Api.handle_event(event, :send_typing, nil)
    assert result.response == {:error, {:no_bridge, :mattermost}}
  end

  test "handles fetch_profile success" do
    event =
      Event.new(%{provider: :mattermost, author_id: "user-1"}, :channels,
        opts: [action: :fetch_profile, bridge_module: StubCommunicationBridge]
      )

    result = Api.handle_event(event, :fetch_profile, nil)

    assert result.response == {:ok, %{id: "user-1"}}
    assert_received {:bridge_fetch_profile, "user-1", details}
    assert details.provider == :mattermost
  end

  test "fetch_profile returns unsupported when callback is missing" do
    event =
      Event.new(%{provider: :mattermost, author_id: "user-1"}, :channels,
        opts: [action: :fetch_profile, bridge_module: StubCommunicationBridgeNoCallbacks]
      )

    result = Api.handle_event(event, :fetch_profile, nil)
    assert result.response == {:error, :unsupported}
  end

  test "fetch_profile returns no_bridge when bridge missing" do
    event =
      Event.new(%{provider: :mattermost, author_id: "user-1"}, :channels,
        opts: [action: :fetch_profile, bridge_module: StubCommunicationBridgeNoBridge]
      )

    result = Api.handle_event(event, :fetch_profile, nil)
    assert result.response == {:error, {:no_bridge, :mattermost}}
  end

  test "handles open_dm_channel success" do
    event =
      Event.new(%{provider: :mattermost, author_id: "user-1"}, :channels,
        opts: [action: :open_dm_channel, bridge_module: StubCommunicationBridge]
      )

    result = Api.handle_event(event, :open_dm_channel, nil)

    assert result.response == {:ok, "dm-1"}
    assert_received {:bridge_open_dm_channel, "user-1", details}
    assert details.provider == :mattermost
    assert Map.has_key?(details, :bot_user_id)
  end

  test "open_dm_channel returns channel config errors" do
    event =
      Event.new(%{provider: :mattermost, author_id: "user-1"}, :channels,
        opts: [action: :open_dm_channel, bridge_module: StubCommunicationBridgeConfigError]
      )

    result = Api.handle_event(event, :open_dm_channel, nil)
    assert result.response == {:error, :channel_not_configured}
  end

  test "open_dm_channel returns unsupported when callback missing" do
    event =
      Event.new(%{provider: :mattermost, author_id: "user-1"}, :channels,
        opts: [action: :open_dm_channel, bridge_module: StubCommunicationBridgeNoCallbacks]
      )

    result = Api.handle_event(event, :open_dm_channel, nil)
    assert result.response == {:error, :unsupported}
  end

  test "handles list_mailboxes success" do
    event =
      Event.new(%{provider: :mattermost, config: %{mailbox: true}}, :channels,
        opts: [action: :list_mailboxes, bridge_module: StubCommunicationBridge]
      )

    result = Api.handle_event(event, :list_mailboxes, nil)
    assert result.response == {:ok, ["INBOX"]}
    assert_received {:bridge_list_mailboxes, config, details}
    assert config.provider == "mattermost"
    assert is_map(details)
  end

  test "list_mailboxes returns unsupported when callback missing" do
    event =
      Event.new(%{provider: :mattermost, config: %{}}, :channels,
        opts: [action: :list_mailboxes, bridge_module: StubCommunicationBridgeNoCallbacks]
      )

    result = Api.handle_event(event, :list_mailboxes, nil)
    assert result.response == {:error, :unsupported}
  end

  test "bridge_available returns true and false" do
    yes_event =
      Event.new(%{platform: "mattermost"}, :channels,
        opts: [bridge_module: StubCommunicationBridge]
      )

    no_event =
      Event.new(%{platform: "mattermost"}, :channels,
        opts: [bridge_module: StubCommunicationBridgeNoBridge]
      )

    assert Api.handle_event(yes_event, :bridge_available, nil).response == true
    assert Api.handle_event(no_event, :bridge_available, nil).response == false
  end

  test "test_connection returns unsupported when callback missing" do
    config = %ChannelConfig{id: 42, provider: "mattermost"}

    event =
      Event.new(%{config: config, channel_id: "chan-1"}, :channels,
        opts: [action: :test_connection, bridge_module: StubCommunicationBridgeNoCallbacks]
      )

    result = Api.handle_event(event, :test_connection, nil)
    assert result.response == {:error, :unsupported}
  end

  test "test_connection returns no_bridge when bridge is missing" do
    config = %ChannelConfig{id: 42, provider: "mattermost"}

    event =
      Event.new(%{config: config, channel_id: "chan-1"}, :channels,
        opts: [action: :test_connection, bridge_module: StubCommunicationBridgeNoBridge]
      )

    result = Api.handle_event(event, :test_connection, nil)
    assert result.response == {:error, {:no_bridge, "mattermost"}}
  end

  test "returns unsupported_action for unhandled action" do
    event = Event.new(%{provider: :mattermost, author_id: "u"}, :channels)
    result = Api.handle_event(event, :unknown_action, nil)
    assert result.response == {:error, {:unsupported_action, :unknown_action}}
  end

  test "returns unsupported_action when action payload shape does not match callback guards" do
    bad_send_typing = Event.new(%{provider: :mattermost, channel_id: 123}, :channels)
    bad_fetch_profile = Event.new(%{provider: :mattermost, author_id: 123}, :channels)
    bad_open_dm = Event.new(%{provider: :mattermost, author_id: 123}, :channels)
    bad_list_mailboxes = Event.new(%{provider: :mattermost, config: "bad"}, :channels)
    bad_bridge_available = Event.new(%{platform: :mattermost}, :channels)

    assert Api.handle_event(bad_send_typing, :send_typing, nil).response ==
             {:error, {:unsupported_action, :send_typing}}

    assert Api.handle_event(bad_fetch_profile, :fetch_profile, nil).response ==
             {:error, {:unsupported_action, :fetch_profile}}

    assert Api.handle_event(bad_open_dm, :open_dm_channel, nil).response ==
             {:error, {:unsupported_action, :open_dm_channel}}

    assert Api.handle_event(bad_list_mailboxes, :list_mailboxes, nil).response ==
             {:error, {:unsupported_action, :list_mailboxes}}

    assert Api.handle_event(bad_bridge_available, :bridge_available, nil).response ==
             {:error, {:unsupported_action, :bridge_available}}
  end

  test "uses communication_bridge_module option when bridge_module is missing" do
    outgoing = %Outgoing{body: "ok", channel_id: "c1", provider: :web}

    event =
      Event.new(outgoing, :channels,
        opts: [action: :deliver_outgoing, communication_bridge_module: StubCommunicationBridge]
      )

    result = Api.handle_event(event, :deliver_outgoing, nil)
    assert result.response == :ok
    assert_received {:bridge_send_reply, ^outgoing, _details}
  end

  test "falls back to default bridge module when opts are not a keyword list" do
    outgoing = %Outgoing{body: "ok", channel_id: "c1", provider: :web}
    event = Event.new(outgoing, :channels)
    result = Api.handle_event(%{event | opts: :invalid_opts}, :deliver_outgoing, nil)

    assert result.response == :ok
  end
end

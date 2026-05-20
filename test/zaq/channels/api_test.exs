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

    def capability_snapshot(provider) do
      send(self(), {:bridge_capability_snapshot, provider})

      {:ok,
       %{
         kind: :communication,
         required: [:text],
         resolved: %{text: true},
         unsupported: [],
         labels: %{text: "Text"}
       }}
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

    def handle_webhook(config, payload) do
      send(self(), {:bridge_handle_webhook, config, payload})
      {:ok, %{accepted: true}}
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

  defmodule StubDataSourceBridge do
    def auth_handshake(provider, params) do
      send(self(), {:ds_auth_handshake, provider, params})
      {:ok, %{provider: provider}}
    end

    def list_resources(provider, params) do
      send(self(), {:ds_list_resources, provider, params})
      {:ok, [%{"id" => "r1"}]}
    end

    def download_resource(provider, resource, params) do
      send(self(), {:ds_download_resource, provider, resource, params})
      {:ok, %{resource: resource, params: params}}
    end

    def setup_listener(provider, params) do
      send(self(), {:ds_setup_listener, provider, params})
      {:ok, %{listener_id: "l1"}}
    end

    def create_file(provider, params) do
      send(self(), {:ds_create_file, provider, params})
      {:ok, %{status: "created", record: %{"id" => "f1"}}}
    end

    def get_file(provider, params) do
      send(self(), {:ds_get_file, provider, params})
      {:ok, %{record: %{"id" => "f1"}}}
    end

    def update_file(provider, params) do
      send(self(), {:ds_update_file, provider, params})
      {:ok, %{status: "updated", record: %{"id" => "f1"}}}
    end

    def delete_file(provider, params) do
      send(self(), {:ds_delete_file, provider, params})
      {:ok, %{status: "deleted", result: %{}}}
    end

    def search_files(provider, params) do
      send(self(), {:ds_search_files, provider, params})
      {:ok, %{records: [%{"id" => "f1"}]}}
    end

    def teardown_listener(provider, params) do
      send(self(), {:ds_teardown_listener, provider, params})
      :ok
    end

    def channel_stats(provider, params) do
      send(self(), {:ds_channel_stats, provider, params})
      {:ok, %{files_count: 10, folders_count: 3, principals_count: 7, root_folders: ["Root"]}}
    end

    def sync_config_runtime(before_config, after_config) do
      send(self(), {:ds_sync_config_runtime, before_config, after_config})
      :ok
    end

    def sync_provider_runtime(provider) do
      send(self(), {:ds_sync_provider_runtime, provider})
      :ok
    end

    def handle_webhook(provider, payload) do
      send(self(), {:ds_handle_webhook, provider, payload})
      {:ok, %{provider: provider, handled: true}}
    end
  end

  defmodule StubCommunicationWebhookBridge do
    def handle_webhook(provider, payload) do
      send(self(), {:comm_handle_webhook, provider, payload})
      {:ok, %{provider: provider, handled: true}}
    end
  end

  defmodule StubCommunicationWebhookPassthroughBridge do
    def handle_webhook(provider, payload) do
      send(self(), {:comm_handle_webhook_passthrough, provider, payload})

      {:ok,
       %{
         webhook_response: %{
           status: 200,
           headers: %{"x-provider" => to_string(provider)},
           body: "ok"
         }
       }}
    end
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

  test "handles data_source_auth_handshake action" do
    event =
      Event.new(%{provider: :google_drive, params: %{"scope" => "read"}}, :channels,
        opts: [
          action: :data_source_auth_handshake,
          data_source_bridge_module: StubDataSourceBridge
        ]
      )

    result = Api.handle_event(event, :data_source_auth_handshake, nil)
    assert result.response == {:ok, %{provider: :google_drive}}
    assert_received {:ds_auth_handshake, :google_drive, %{"scope" => "read"}}
  end

  test "handles data_source_list_resources action" do
    event =
      Event.new(%{provider: "google_drive", params: %{}}, :channels,
        opts: [
          action: :data_source_list_resources,
          data_source_bridge_module: StubDataSourceBridge
        ]
      )

    result = Api.handle_event(event, :data_source_list_resources, nil)
    assert result.response == {:ok, [%{"id" => "r1"}]}
    assert_received {:ds_list_resources, "google_drive", %{}}
  end

  test "handles data_source_download_resource action" do
    event =
      Event.new(
        %{provider: :google_drive, resource: %{"id" => "r1"}, params: %{"target" => "tmp"}},
        :channels,
        opts: [
          action: :data_source_download_resource,
          data_source_bridge_module: StubDataSourceBridge
        ]
      )

    result = Api.handle_event(event, :data_source_download_resource, nil)
    assert {:ok, %{resource: %{"id" => "r1"}, params: %{"target" => "tmp"}}} = result.response
    assert_received {:ds_download_resource, :google_drive, %{"id" => "r1"}, %{"target" => "tmp"}}
  end

  test "handles data_source_setup_listener action" do
    event =
      Event.new(%{provider: :google_drive, params: %{"mode" => "delta"}}, :channels,
        opts: [
          action: :data_source_setup_listener,
          data_source_bridge_module: StubDataSourceBridge
        ]
      )

    result = Api.handle_event(event, :data_source_setup_listener, nil)
    assert result.response == {:ok, %{listener_id: "l1"}}
    assert_received {:ds_setup_listener, :google_drive, %{"mode" => "delta"}}
  end

  test "handles data_source_create_file action" do
    event =
      Event.new(%{provider: :google_drive, params: %{"name" => "Doc"}}, :channels,
        opts: [action: :data_source_create_file, data_source_bridge_module: StubDataSourceBridge]
      )

    result = Api.handle_event(event, :data_source_create_file, nil)
    assert {:ok, %{status: "created", record: %{"id" => "f1"}}} = result.response
    assert_received {:ds_create_file, :google_drive, %{"name" => "Doc"}}
  end

  test "handles data_source_get_file action" do
    event =
      Event.new(%{provider: :google_drive, params: %{"file_id" => "f1"}}, :channels,
        opts: [action: :data_source_get_file, data_source_bridge_module: StubDataSourceBridge]
      )

    result = Api.handle_event(event, :data_source_get_file, nil)
    assert {:ok, %{record: %{"id" => "f1"}}} = result.response
    assert_received {:ds_get_file, :google_drive, %{"file_id" => "f1"}}
  end

  test "handles data_source_update_file action" do
    event =
      Event.new(
        %{provider: :google_drive, params: %{"file_id" => "f1", "name" => "Renamed"}},
        :channels,
        opts: [action: :data_source_update_file, data_source_bridge_module: StubDataSourceBridge]
      )

    result = Api.handle_event(event, :data_source_update_file, nil)
    assert {:ok, %{status: "updated", record: %{"id" => "f1"}}} = result.response
    assert_received {:ds_update_file, :google_drive, %{"file_id" => "f1", "name" => "Renamed"}}
  end

  test "handles data_source_delete_file action" do
    event =
      Event.new(%{provider: :google_drive, params: %{"file_id" => "f1"}}, :channels,
        opts: [action: :data_source_delete_file, data_source_bridge_module: StubDataSourceBridge]
      )

    result = Api.handle_event(event, :data_source_delete_file, nil)
    assert {:ok, %{status: "deleted", result: %{}}} = result.response
    assert_received {:ds_delete_file, :google_drive, %{"file_id" => "f1"}}
  end

  test "handles data_source_search_files action" do
    event =
      Event.new(%{provider: :google_drive, params: %{"query" => "invoice"}}, :channels,
        opts: [action: :data_source_search_files, data_source_bridge_module: StubDataSourceBridge]
      )

    result = Api.handle_event(event, :data_source_search_files, nil)
    assert {:ok, %{records: [%{"id" => "f1"}]}} = result.response
    assert_received {:ds_search_files, :google_drive, %{"query" => "invoice"}}
  end

  test "handles webhook_delivered for data_source" do
    payload = %{"headers" => %{"x-test" => "1"}, "params" => %{"event" => "file.changed"}}

    event =
      Event.new(%{type: "data_source", provider: "google_drive", payload: payload}, :channels,
        opts: [action: :webhook_delivered, data_source_bridge_module: StubDataSourceBridge]
      )

    result = Api.handle_event(event, :webhook_delivered, nil)
    assert result.response == {:ok, %{provider: "google_drive", handled: true}}
    assert_received {:ds_handle_webhook, "google_drive", ^payload}
  end

  test "handles webhook_delivered for conversation" do
    payload = %{"headers" => %{"x-test" => "1"}, "params" => %{"event" => "message"}}

    event =
      Event.new(%{type: "conversation", provider: "slack", payload: payload}, :channels,
        opts: [
          action: :webhook_delivered,
          communication_bridge_module: StubCommunicationWebhookBridge
        ]
      )

    result = Api.handle_event(event, :webhook_delivered, nil)
    assert result.response == {:ok, %{provider: "slack", handled: true}}
    assert_received {:comm_handle_webhook, "slack", ^payload}
  end

  test "passes through conversation webhook response payload" do
    payload = %{"headers" => %{"x-test" => "1"}, "params" => %{"event" => "message"}}

    event =
      Event.new(%{type: "conversation", provider: "telegram", payload: payload}, :channels,
        opts: [
          action: :webhook_delivered,
          communication_bridge_module: StubCommunicationWebhookPassthroughBridge
        ]
      )

    result = Api.handle_event(event, :webhook_delivered, nil)

    assert result.response ==
             {:ok,
              %{
                webhook_response: %{
                  status: 200,
                  headers: %{"x-provider" => "telegram"},
                  body: "ok"
                }
              }}

    assert_received {:comm_handle_webhook_passthrough, "telegram", ^payload}
  end

  test "handles data_source_teardown_listener action" do
    event =
      Event.new(%{provider: :google_drive, params: %{"listener_id" => "l1"}}, :channels,
        opts: [
          action: :data_source_teardown_listener,
          data_source_bridge_module: StubDataSourceBridge
        ]
      )

    result = Api.handle_event(event, :data_source_teardown_listener, nil)
    assert result.response == :ok
    assert_received {:ds_teardown_listener, :google_drive, %{"listener_id" => "l1"}}
  end

  test "handles data_source_channel_stats action" do
    event =
      Event.new(%{provider: :google_drive, params: %{"resource_id" => 9}}, :channels,
        opts: [
          action: :data_source_channel_stats,
          data_source_bridge_module: StubDataSourceBridge
        ]
      )

    result = Api.handle_event(event, :data_source_channel_stats, nil)

    assert result.response ==
             {:ok,
              %{files_count: 10, folders_count: 3, principals_count: 7, root_folders: ["Root"]}}

    assert_received {:ds_channel_stats, :google_drive, %{"resource_id" => 9}}
  end

  test "handles sync_data_source_runtime action" do
    before_config = %{id: 1, enabled: true}
    after_config = %{id: 1, enabled: false}

    event =
      Event.new(%{before_config: before_config, after_config: after_config}, :channels,
        opts: [action: :sync_data_source_runtime, runtime_module: StubDataSourceBridge]
      )

    result = Api.handle_event(event, :sync_data_source_runtime, nil)
    assert result.response == :ok
    assert_received {:ds_sync_config_runtime, ^before_config, ^after_config}
  end

  test "handles sync_data_source_provider_runtime action" do
    event =
      Event.new(%{provider: :google_drive}, :channels,
        opts: [action: :sync_data_source_provider_runtime, runtime_module: StubDataSourceBridge]
      )

    result = Api.handle_event(event, :sync_data_source_provider_runtime, nil)
    assert result.response == :ok
    assert_received {:ds_sync_provider_runtime, :google_drive}
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

  test "handles channel_capability_snapshot" do
    event =
      Event.new(%{provider: "mattermost"}, :channels,
        opts: [action: :channel_capability_snapshot, bridge_module: StubCommunicationBridge]
      )

    result = Api.handle_event(event, :channel_capability_snapshot, nil)

    assert result.response ==
             {:ok,
              %{
                kind: :communication,
                required: [:text],
                resolved: %{text: true},
                unsupported: [],
                labels: %{text: "Text"}
              }}

    assert_received {:bridge_capability_snapshot, "mattermost"}
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
    bad_send_typing = Event.new(%{provider: :mattermost}, :channels)
    bad_fetch_profile = Event.new(%{provider: :mattermost}, :channels)
    bad_open_dm = Event.new(%{provider: :mattermost}, :channels)
    bad_list_mailboxes = Event.new(%{provider: :mattermost, config: "bad"}, :channels)
    bad_bridge_available = Event.new(%{platform: :mattermost}, :channels)
    bad_data_source_auth = Event.new(%{provider: :google_drive, params: "bad"}, :channels)

    bad_data_source_download =
      Event.new(%{provider: :google_drive, resource: %{}, params: "bad"}, :channels)

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

    assert Api.handle_event(bad_data_source_auth, :data_source_auth_handshake, nil).response ==
             {:error, {:unsupported_action, :data_source_auth_handshake}}

    assert Api.handle_event(bad_data_source_download, :data_source_download_resource, nil).response ==
             {:error, {:unsupported_action, :data_source_download_resource}}
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

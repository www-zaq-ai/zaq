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

  defmodule StubIngressRuntimeModule do
    def ensure_ingress_subscription(provider, params) do
      send(self(), {:ensure_ingress_subscription, provider, params})
      {:ok, %{subscription_id: "sub-1"}}
    end

    def delete_ingress_subscription(provider, params) do
      send(self(), {:delete_ingress_subscription, provider, params})
      :ok
    end
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

    def upsert_message(config, request, details) do
      send(self(), {:bridge_upsert_message, config, request, details})

      {:ok,
       %{action: :created, message_id: "m-1", update_intent: Map.get(request, :update_intent)}}
    end

    def channel_ingress_status(config) do
      send(self(), {:bridge_channel_ingress_status, config})
      {:ok, %{status: :ok, mode: "websocket", summary: "running"}}
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

    def download_document(provider, params) do
      send(self(), {:ds_download_document, provider, params})
      {:ok, %{record: %{id: "f1", kind: :file, content: "hello"}}}
    end

    def teardown_listener(provider, params) do
      send(self(), {:ds_teardown_listener, provider, params})
      :ok
    end

    def channel_stats(provider, params) do
      send(self(), {:ds_channel_stats, provider, params})
      {:ok, %{files_count: 10, folders_count: 3, principals_count: 7, root_folders: ["Root"]}}
    end

    def export_options(provider, params) do
      send(self(), {:ds_export_options, provider, params})

      {:ok,
       %{
         native_types: ["application/vnd.google-apps.document"],
         export_formats_by_native_type: %{
           "application/vnd.google-apps.document" => ["text/plain", "application/pdf"]
         }
       }}
    end

    def sheet_inspect(provider, params) do
      send(self(), {:ds_sheet_inspect, provider, params})

      {:ok,
       %{
         record: %{
           id: "s1",
           kind: :spreadsheet,
           name: "Budget",
           attributes: %{"tabs" => [%{"sheet_id" => "0", "title" => "Sheet1"}]}
         }
       }}
    end

    def sheet_add_tab(provider, params) do
      send(self(), {:ds_sheet_add_tab, provider, params})

      {:ok,
       %{
         status: "created",
         record: %{
           id: "s1",
           kind: :spreadsheet,
           attributes: %{"tab" => %{"sheet_id" => "99", "title" => Map.get(params, "title")}}
         }
       }}
    end

    def sheet_get(provider, params) do
      send(self(), {:ds_sheet_get, provider, params})
      {:ok, %{record: %{id: Map.get(params, "spreadsheet_id"), tab: Map.get(params, "tab")}}}
    end

    def sheet_create(provider, params) do
      send(self(), {:ds_sheet_create, provider, params})
      {:ok, %{status: "created", record: %{id: "s-new", kind: :spreadsheet}}}
    end

    def sheet_update_values(provider, params) do
      send(self(), {:ds_sheet_update_values, provider, params})
      {:ok, %{status: "updated", updated_cells: 2}}
    end

    def sheet_append_values(provider, params) do
      send(self(), {:ds_sheet_append_values, provider, params})
      {:ok, %{status: "appended", updated_rows: 1}}
    end

    def sheet_clear_values(provider, params) do
      send(self(), {:ds_sheet_clear_values, provider, params})
      {:ok, %{status: "cleared"}}
    end

    def sheet_delete_tab(provider, params) do
      send(self(), {:ds_sheet_delete_tab, provider, params})
      {:ok, %{status: "deleted"}}
    end

    def list_permissions(provider, params) do
      send(self(), {:ds_list_permissions, provider, params})
      {:ok, %{permissions: [%{"id" => "p1", "role" => "reader"}]}}
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

  defmodule StubDataSourceBridgeUpdateValuesError do
    def sheet_update_values(provider, params) do
      send(self(), {:ds_sheet_update_values_error, provider, params})
      {:error, :invalid_range}
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

  test "deliver_outgoing injects status_message_id into message_id" do
    outgoing = %Outgoing{
      body: "ok",
      channel_id: "c1",
      provider: :web,
      metadata: %{request_id: "r1", status_message_id: "m-status"}
    }

    event =
      Event.new(outgoing, :channels,
        opts: [
          action: :deliver_outgoing,
          bridge_module: StubCommunicationBridge
        ]
      )

    result = Api.handle_event(event, :deliver_outgoing, nil)

    assert result.response == :ok
    assert_received {:bridge_send_reply, %Outgoing{metadata: %{message_id: "m-status"}}, _details}
  end

  describe "deliver_outgoing metadata preservation" do
    test "deliver_outgoing keeps existing message_id and does not overwrite it with status_message_id" do
      outgoing = %Outgoing{
        body: "ok",
        channel_id: "c1",
        provider: :web,
        metadata: %{message_id: "m-existing", status_message_id: "m-status", request_id: "r1"}
      }

      event =
        Event.new(outgoing, :channels,
          opts: [action: :deliver_outgoing, bridge_module: StubCommunicationBridge]
        )

      result = Api.handle_event(event, :deliver_outgoing, nil)

      assert result.response == :ok
      assert_received {:bridge_send_reply, %Outgoing{metadata: metadata}, _details}
      assert metadata[:message_id] == "m-existing"
      assert metadata[:status_message_id] == "m-status"
    end
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

  test "handles upsert_message action" do
    request = %{provider: :web, channel_id: "c1", request_id: "r1", body: "partial"}

    event =
      Event.new(request, :channels,
        opts: [
          action: :upsert_message,
          bridge_module: StubCommunicationBridge
        ]
      )

    result = Api.handle_event(event, :upsert_message, nil)

    assert result.response == {:ok, %{action: :created, message_id: "m-1", update_intent: nil}}

    assert_received {:bridge_upsert_message, %{id: 1, provider: "mattermost"}, bridged_request,
                     %{url: "https://example.test", token: "token"}}

    assert Map.take(bridged_request, Map.keys(request)) == request
  end

  test "upsert_message maps status_message_id into message_id" do
    request = %{
      provider: :web,
      channel_id: "c1",
      request_id: "r1",
      body: "partial",
      status_message_id: "m-status"
    }

    event =
      Event.new(request, :channels,
        opts: [
          action: :upsert_message,
          bridge_module: StubCommunicationBridge
        ]
      )

    result = Api.handle_event(event, :upsert_message, nil)

    assert result.response == {:ok, %{action: :created, message_id: "m-1", update_intent: nil}}

    assert_received {:bridge_upsert_message, %{id: 1, provider: "mattermost"}, bridged_request,
                     %{url: "https://example.test", token: "token"}}

    assert bridged_request.message_id == "m-status"
  end

  test "upsert_message maps integer status_message_id into message_id" do
    request = %{
      provider: :web,
      channel_id: "c1",
      request_id: "r1",
      body: "partial",
      status_message_id: 52
    }

    event =
      Event.new(request, :channels,
        opts: [
          action: :upsert_message,
          bridge_module: StubCommunicationBridge
        ]
      )

    result = Api.handle_event(event, :upsert_message, nil)

    assert result.response == {:ok, %{action: :created, message_id: "m-1", update_intent: nil}}

    assert_received {:bridge_upsert_message, %{id: 1, provider: "mattermost"}, bridged_request,
                     %{url: "https://example.test", token: "token"}}

    assert bridged_request.message_id == 52
  end

  test "upsert_message preserves tool_call intent while mapping status_message_id" do
    request = %{
      provider: :web,
      channel_id: "c1",
      request_id: "r1",
      body: "Calling mcp__read_file...",
      status_message_id: "m-status",
      update_intent: :tool_call
    }

    event =
      Event.new(request, :channels,
        opts: [
          action: :upsert_message,
          bridge_module: StubCommunicationBridge
        ]
      )

    result = Api.handle_event(event, :upsert_message, nil)

    assert result.response ==
             {:ok, %{action: :created, message_id: "m-1", update_intent: :tool_call}}

    assert_received {:bridge_upsert_message, _cfg, bridged_request, _details}
    assert bridged_request.message_id == "m-status"
    assert bridged_request.update_intent == :tool_call
  end

  test "upsert_message returns error for unsupported intents" do
    request = %{
      provider: :web,
      channel_id: "c1",
      request_id: "r1",
      body: "partial",
      update_intent: :not_supported
    }

    event =
      Event.new(request, :channels,
        opts: [action: :upsert_message, bridge_module: StubCommunicationBridge]
      )

    result = Api.handle_event(event, :upsert_message, nil)
    assert result.response == {:error, :unsupported_update_intent}
    refute_received {:bridge_upsert_message, _, _, _}
  end

  describe "upsert_message uncovered branches" do
    test "upsert_message returns fetch_channel_config error for non-web provider" do
      request = %{provider: :mattermost, channel_id: "c1", request_id: "r1", body: "partial"}

      event =
        Event.new(request, :channels,
          opts: [action: :upsert_message, bridge_module: StubCommunicationBridgeConfigError]
        )

      result = Api.handle_event(event, :upsert_message, nil)

      assert result.response == {:error, :channel_not_configured}
      refute_received {:bridge_upsert_message, _, _, _}
    end

    test "upsert_message accepts update_intent as supported binary" do
      request = %{
        provider: :web,
        channel_id: "c1",
        request_id: "r1",
        body: "partial",
        update_intent: "tool_call"
      }

      event =
        Event.new(request, :channels,
          opts: [action: :upsert_message, bridge_module: StubCommunicationBridge]
        )

      result = Api.handle_event(event, :upsert_message, nil)

      assert result.response ==
               {:ok, %{action: :created, message_id: "m-1", update_intent: "tool_call"}}

      assert_received {:bridge_upsert_message, _cfg, _request, _details}
    end

    test "upsert_message rejects unknown binary update_intent" do
      request = %{
        provider: :web,
        channel_id: "c1",
        request_id: "r1",
        body: "partial",
        update_intent: "totally_unknown_intent_xyz"
      }

      event =
        Event.new(request, :channels,
          opts: [action: :upsert_message, bridge_module: StubCommunicationBridge]
        )

      result = Api.handle_event(event, :upsert_message, nil)

      assert result.response == {:error, :unsupported_update_intent}
      refute_received {:bridge_upsert_message, _, _, _}
    end

    test "upsert_message rejects non atom/binary update_intent" do
      request = %{
        provider: :web,
        channel_id: "c1",
        request_id: "r1",
        body: "partial",
        update_intent: 123
      }

      event =
        Event.new(request, :channels,
          opts: [action: :upsert_message, bridge_module: StubCommunicationBridge]
        )

      result = Api.handle_event(event, :upsert_message, nil)

      assert result.response == {:error, :unsupported_update_intent}
      refute_received {:bridge_upsert_message, _, _, _}
    end
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

  describe "channel ingress runtime actions" do
    test "handles channel_ensure_ingress_subscription via runtime_module option" do
      event =
        Event.new(%{provider: :mattermost, params: %{"channel_id" => "c1"}}, :channels,
          opts: [
            action: :channel_ensure_ingress_subscription,
            runtime_module: StubIngressRuntimeModule
          ]
        )

      result = Api.handle_event(event, :channel_ensure_ingress_subscription, nil)

      assert result.response == {:ok, %{subscription_id: "sub-1"}}
      assert_received {:ensure_ingress_subscription, :mattermost, %{"channel_id" => "c1"}}
    end

    test "handles channel_delete_ingress_subscription via runtime_module option" do
      event =
        Event.new(%{provider: :mattermost, params: %{"subscription_id" => "sub-1"}}, :channels,
          opts: [
            action: :channel_delete_ingress_subscription,
            runtime_module: StubIngressRuntimeModule
          ]
        )

      result = Api.handle_event(event, :channel_delete_ingress_subscription, nil)

      assert result.response == :ok
      assert_received {:delete_ingress_subscription, :mattermost, %{"subscription_id" => "sub-1"}}
    end

    test "channel ingress subscription actions return unsupported_action when params is not a map" do
      ensure_event = Event.new(%{provider: :mattermost, params: "bad"}, :channels)
      delete_event = Event.new(%{provider: :mattermost, params: "bad"}, :channels)

      assert Api.handle_event(ensure_event, :channel_ensure_ingress_subscription, nil).response ==
               {:error, {:unsupported_action, :channel_ensure_ingress_subscription}}

      assert Api.handle_event(delete_event, :channel_delete_ingress_subscription, nil).response ==
               {:error, {:unsupported_action, :channel_delete_ingress_subscription}}
    end
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

  test "handles data_source_download_document action" do
    event =
      Event.new(%{provider: :google_drive, params: %{"file_id" => "f1"}}, :channels,
        opts: [
          action: :data_source_download_document,
          data_source_bridge_module: StubDataSourceBridge
        ]
      )

    result = Api.handle_event(event, :data_source_download_document, nil)
    assert {:ok, %{record: %{id: "f1", kind: :file, content: "hello"}}} = result.response
    assert_received {:ds_download_document, :google_drive, %{"file_id" => "f1"}}
  end

  test "handles data_source_export_options action" do
    event =
      Event.new(%{provider: :google_drive, params: %{"config_id" => "12"}}, :channels,
        opts: [
          action: :data_source_export_options,
          data_source_bridge_module: StubDataSourceBridge
        ]
      )

    result = Api.handle_event(event, :data_source_export_options, nil)

    assert {:ok, %{native_types: [_ | _], export_formats_by_native_type: %{}}} = result.response
    assert_received {:ds_export_options, :google_drive, %{"config_id" => "12"}}
  end

  describe "data source sheet CRUD/value actions" do
    test "handles data_source_sheet_inspect action" do
      event =
        Event.new(%{provider: :google_drive, params: %{"spreadsheet_id" => "s1"}}, :channels,
          opts: [
            action: :data_source_sheet_inspect,
            data_source_bridge_module: StubDataSourceBridge
          ]
        )

      result = Api.handle_event(event, :data_source_sheet_inspect, nil)

      assert {:ok, %{record: %{id: "s1", kind: :spreadsheet}}} =
               result.response

      assert_received {:ds_sheet_inspect, :google_drive, %{"spreadsheet_id" => "s1"}}
    end

    test "handles data_source_sheet_get action" do
      params = %{"spreadsheet_id" => "s1", "tab" => "Sheet1"}

      event =
        Event.new(%{provider: :google_drive, params: params}, :channels,
          opts: [
            action: :data_source_sheet_get,
            data_source_bridge_module: StubDataSourceBridge
          ]
        )

      result = Api.handle_event(event, :data_source_sheet_get, nil)

      assert result.response == {:ok, %{record: %{id: "s1", tab: "Sheet1"}}}
      assert_received {:ds_sheet_get, :google_drive, ^params}
    end

    test "handles data_source_sheet_create action" do
      params = %{"spreadsheet_id" => "s-new", "title" => "Q1"}

      event =
        Event.new(%{provider: :google_drive, params: params}, :channels,
          opts: [
            action: :data_source_sheet_create,
            data_source_bridge_module: StubDataSourceBridge
          ]
        )

      result = Api.handle_event(event, :data_source_sheet_create, nil)

      assert result.response ==
               {:ok, %{status: "created", record: %{id: "s-new", kind: :spreadsheet}}}

      assert_received {:ds_sheet_create, :google_drive, ^params}
    end

    test "handles data_source_sheet_update_values action" do
      params = %{"spreadsheet_id" => "s1", "range" => "A1:B1", "values" => [["1", "2"]]}

      event =
        Event.new(%{provider: :google_drive, params: params}, :channels,
          opts: [
            action: :data_source_sheet_update_values,
            data_source_bridge_module: StubDataSourceBridge
          ]
        )

      result = Api.handle_event(event, :data_source_sheet_update_values, nil)

      assert result.response == {:ok, %{status: "updated", updated_cells: 2}}
      assert_received {:ds_sheet_update_values, :google_drive, ^params}
    end

    test "handles data_source_sheet_append_values action" do
      params = %{"spreadsheet_id" => "s1", "range" => "A1:B1", "values" => [["1", "2"]]}

      event =
        Event.new(%{provider: :google_drive, params: params}, :channels,
          opts: [
            action: :data_source_sheet_append_values,
            data_source_bridge_module: StubDataSourceBridge
          ]
        )

      result = Api.handle_event(event, :data_source_sheet_append_values, nil)

      assert result.response == {:ok, %{status: "appended", updated_rows: 1}}
      assert_received {:ds_sheet_append_values, :google_drive, ^params}
    end

    test "handles data_source_sheet_clear_values action" do
      params = %{"spreadsheet_id" => "s1", "range" => "A1:B1"}

      event =
        Event.new(%{provider: :google_drive, params: params}, :channels,
          opts: [
            action: :data_source_sheet_clear_values,
            data_source_bridge_module: StubDataSourceBridge
          ]
        )

      result = Api.handle_event(event, :data_source_sheet_clear_values, nil)

      assert result.response == {:ok, %{status: "cleared"}}
      assert_received {:ds_sheet_clear_values, :google_drive, ^params}
    end

    test "data_source_sheet_clear_values accepts empty params map" do
      event =
        Event.new(%{provider: :google_drive, params: %{}}, :channels,
          opts: [
            action: :data_source_sheet_clear_values,
            data_source_bridge_module: StubDataSourceBridge
          ]
        )

      result = Api.handle_event(event, :data_source_sheet_clear_values, nil)

      assert result.response == {:ok, %{status: "cleared"}}
      assert_received {:ds_sheet_clear_values, :google_drive, %{}}
    end

    test "handles data_source_sheet_delete_tab action" do
      params = %{"spreadsheet_id" => "s1", "tab_id" => "0"}

      event =
        Event.new(%{provider: :google_drive, params: params}, :channels,
          opts: [
            action: :data_source_sheet_delete_tab,
            data_source_bridge_module: StubDataSourceBridge
          ]
        )

      result = Api.handle_event(event, :data_source_sheet_delete_tab, nil)

      assert result.response == {:ok, %{status: "deleted"}}
      assert_received {:ds_sheet_delete_tab, :google_drive, ^params}
    end

    test "data_source_sheet_update_values passes through bridge error tuple" do
      params = %{"spreadsheet_id" => "s1", "range" => "A1:B1"}

      event =
        Event.new(%{provider: :google_drive, params: params}, :channels,
          opts: [
            action: :data_source_sheet_update_values,
            data_source_bridge_module: StubDataSourceBridgeUpdateValuesError
          ]
        )

      result = Api.handle_event(event, :data_source_sheet_update_values, nil)

      assert result.response == {:error, :invalid_range}
      assert_received {:ds_sheet_update_values_error, :google_drive, ^params}
    end

    test "handles data_source_sheet_add_tab action" do
      event =
        Event.new(
          %{provider: :google_drive, params: %{"spreadsheet_id" => "s1", "title" => "New Tab"}},
          :channels,
          opts: [
            action: :data_source_sheet_add_tab,
            data_source_bridge_module: StubDataSourceBridge
          ]
        )

      result = Api.handle_event(event, :data_source_sheet_add_tab, nil)

      assert {:ok, %{status: "created", record: %{kind: :spreadsheet}}} = result.response

      assert_received {:ds_sheet_add_tab, :google_drive,
                       %{"spreadsheet_id" => "s1", "title" => "New Tab"}}
    end
  end

  test "handles data_source_list_permissions action" do
    provider = :google_drive
    params = %{"file_id" => "f1", "config_id" => "12"}

    event =
      Event.new(%{provider: provider, params: params}, :channels,
        opts: [
          action: :data_source_list_permissions,
          data_source_bridge_module: StubDataSourceBridge
        ]
      )

    result = Api.handle_event(event, :data_source_list_permissions, nil)

    assert result.response == {:ok, %{permissions: [%{"id" => "p1", "role" => "reader"}]}}

    assert_received {:ds_list_permissions, :google_drive,
                     %{"file_id" => "f1", "config_id" => "12"}}
  end

  test "data_source_list_permissions accepts empty params map" do
    event =
      Event.new(%{provider: :google_drive, params: %{}}, :channels,
        opts: [
          action: :data_source_list_permissions,
          data_source_bridge_module: StubDataSourceBridge
        ]
      )

    result = Api.handle_event(event, :data_source_list_permissions, nil)

    assert result.response == {:ok, %{permissions: [%{"id" => "p1", "role" => "reader"}]}}
    assert_received {:ds_list_permissions, :google_drive, %{}}
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

  test "handles channel_ingress_status with provider config lookup" do
    event =
      Event.new(%{provider: "mattermost"}, :channels,
        opts: [action: :channel_ingress_status, bridge_module: StubCommunicationBridge]
      )

    result = Api.handle_event(event, :channel_ingress_status, nil)

    assert result.response == {:ok, %{status: :ok, mode: "websocket", summary: "running"}}
    assert_received {:bridge_channel_ingress_status, %{id: 1, provider: "mattermost"}}
  end

  describe "channel_ingress_status config override" do
    test "channel_ingress_status uses request config map directly" do
      event =
        Event.new(
          %{provider: "mattermost", config: %{provider: "mattermost", token: "x"}},
          :channels,
          opts: [
            action: :channel_ingress_status,
            bridge_module: StubCommunicationBridgeConfigError
          ]
        )

      result = Api.handle_event(event, :channel_ingress_status, nil)

      assert result.response == {:ok, %{status: :ok, mode: "websocket", summary: "running"}}
      assert_received {:bridge_channel_ingress_status, %{provider: "mattermost", token: "x"}}
    end
  end

  test "channel_ingress_status returns unsupported when callback missing" do
    event =
      Event.new(%{provider: "mattermost"}, :channels,
        opts: [action: :channel_ingress_status, bridge_module: StubCommunicationBridgeNoCallbacks]
      )

    result = Api.handle_event(event, :channel_ingress_status, nil)
    assert result.response == {:error, :unsupported}
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

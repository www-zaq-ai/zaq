defmodule Zaq.Channels.JidoConnectBridgeCoverageGapsTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.JidoConnectBridge
  alias Zaq.Channels.JidoConnectBridgeTest, as: BridgeTest

  alias BridgeTest.StubIntegration, as: BridgeStubIntegration

  defmodule StubJidoConnectStatsEdgeCases do
    def actions(_integration) do
      {:ok,
       [
         %{id: "stub.files.list", resource: :file, verb: :list, auth_profiles: [:user]},
         %{
           id: "stub.permissions.list",
           resource: :permission,
           verb: :list,
           auth_profiles: [:user]
         },
         %{id: "stub.files.get", resource: :file, verb: :get, auth_profiles: [:user]}
       ]}
    end

    def invoke(_integration, "stub.files.list", _params, _opts) do
      {:ok,
       %{
         files: [
           %{
             "id" => "root-empty",
             "name" => "Empty Parent",
             "mimeType" => "application/vnd.google-apps.folder",
             "parent_id" => ""
           },
           %{
             "id" => "child",
             "name" => "Child",
             "mimeType" => "application/vnd.google-apps.folder",
             "parent_id" => "root"
           },
           %{
             "id" => "bad-scalars",
             "name" => "Bad Scalars",
             "mimeType" => "application/pdf",
             "permissions" => "oops",
             "owners" => 123
           },
           %{
             "id" => "mixed-principals",
             "name" => "Mixed Principals",
             "mimeType" => "application/pdf",
             "permissions" => [
               %{"id" => "p1", "emailAddress" => "", "domain" => "", "type" => ""},
               "skip-me"
             ],
             "owners" => [%{"id" => "o1", "emailAddress" => "", "domain" => "", "type" => ""}]
           }
         ]
       }}
    end

    def invoke(_integration, "stub.permissions.list", %{file_id: _file_id}, _opts) do
      {:ok,
       %{
         permissions: [
           %{"id" => "p1", "emailAddress" => "", "domain" => "", "type" => ""},
           "skip-me"
         ]
       }}
    end

    def invoke(_integration, "stub.files.get", _params, _opts) do
      {:ok, %{file: %{"id" => "file-1", "name" => "File 1", "mimeType" => "application/pdf"}}}
    end

    def triggers(_integration),
      do: {:ok, [%{id: "stub.file.changed", kind: :webhook, verb: :watch}]}
  end

  defmodule StubJidoConnectErrorReason do
    def actions(_integration),
      do: {:ok, [%{id: "stub.files.list", resource: :file, verb: :list, auth_profiles: [:user]}]}

    def invoke(_integration, "stub.files.list", _params, _opts) do
      {:error,
       %{
         message: "boom",
         provider: :google_drive,
         status: 429,
         details: %{message: ["rate", "limited"]}
       }}
    end
  end

  defmodule StubJidoConnectTupleProviderReason do
    def actions(_integration),
      do: {:ok, [%{id: "stub.files.list", resource: :file, verb: :list, auth_profiles: [:user]}]}

    def invoke(_integration, "stub.files.list", _params, _opts) do
      {:error,
       %{
         message: "boom",
         provider: {:google_drive, :v2},
         status: 500,
         details: %{message: [1, 2]}
       }}
    end
  end

  defmodule StubJidoConnectCapabilitySnapshot do
    def actions(_integration) do
      {:ok,
       [
         %{id: "stub.files.list", resource: :file, verb: :list, auth_profiles: [:user]},
         %{
           id: "stub.permissions.list",
           resource: :permission,
           verb: :list,
           auth_profiles: [:user]
         },
         %{id: "stub.files.get", resource: :file, verb: :get, auth_profiles: [:user]}
       ]}
    end

    def triggers(_integration), do: {:ok, []}
  end

  defmodule StubJidoConnectWebhookCreated do
    def actions(_integration) do
      {:ok,
       [
         %{id: "stub.files.get", resource: :file, verb: :get, auth_profiles: [:user]}
       ]}
    end

    def invoke(_integration, "stub.files.get", %{file_id: "file-1"}, _opts) do
      {:ok, %{file: %{"id" => "file-1", "name" => "File 1", "mimeType" => "application/pdf"}}}
    end

    def triggers(_integration),
      do: {:ok, [%{id: "stub.file.changed", kind: :webhook, verb: :watch}]}
  end

  defmodule StructWebhookVerifier do
    defstruct [:normalized_signal]

    def verify_and_normalize(_trigger, _payload) do
      {:ok,
       %__MODULE__{
         normalized_signal: %{
           resource_id: "file-1",
           change_type: "created",
           time: "2026-05-17T00:00:00Z"
         }
       }}
    end
  end

  defmodule StubWebhookNodeRouter do
    def dispatch(%{opts: [action: :data_source_record_changed]} = event) do
      send(self(), {:data_source_record_changed, event.request})
      %{event | response: :ok}
    end

    def dispatch(%{opts: [action: :connect_get_active_grant]} = event),
      do: %{event | response: nil}

    def dispatch(%{opts: [action: :connect_fetch_credential]} = event),
      do: %{event | response: {:error, :not_found}}

    def dispatch(%{opts: [action: :connect_oauth_redirect_uri_for]} = event),
      do: %{event | response: nil}
  end

  test "channel_stats keeps root folders and ignores malformed principals" do
    previous_channels = Application.get_env(:zaq, :channels)
    previous_jido_connect = Application.get_env(:zaq, :jido_connect_bridge_jido_connect_module)
    previous_node_router = Application.get_env(:zaq, :jido_connect_bridge_node_router_module)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{
        bridge: JidoConnectBridge,
        integration: StubIntegration
      }
    })

    Application.put_env(
      :zaq,
      :jido_connect_bridge_jido_connect_module,
      StubJidoConnectStatsEdgeCases
    )

    on_exit(fn ->
      BridgeTest.restore_webhook_env(
        previous_channels,
        previous_jido_connect,
        previous_node_router
      )
    end)

    config = BridgeTest.insert_data_source_config(:google_drive)
    credential = BridgeTest.create_credential!()
    _grant = BridgeTest.create_active_grant!(credential, config.id)

    assert {:ok, stats} = JidoConnectBridge.channel_stats(config, %{})
    assert stats.files_count == 2
    assert stats.folders_count == 2
    assert stats.principals_count == 1
    assert stats.root_folders == ["Empty Parent"]
  end

  test "list_files sanitizes atom and tuple provider errors" do
    previous_jido_connect = Application.get_env(:zaq, :jido_connect_bridge_jido_connect_module)

    Application.put_env(
      :zaq,
      :jido_connect_bridge_jido_connect_module,
      StubJidoConnectErrorReason
    )

    on_exit(fn ->
      if previous_jido_connect,
        do:
          Application.put_env(
            :zaq,
            :jido_connect_bridge_jido_connect_module,
            previous_jido_connect
          ),
        else: Application.delete_env(:zaq, :jido_connect_bridge_jido_connect_module)
    end)

    config = BridgeTest.insert_data_source_config(:google_drive)
    credential = BridgeTest.create_credential!()
    _grant = BridgeTest.create_active_grant!(credential, config.id)

    assert {:error, error} = JidoConnectBridge.list_files(config, %{})
    assert error.provider == "google_drive"
    assert error.code == :provider_rate_limited
    assert error.retryable

    Application.put_env(
      :zaq,
      :jido_connect_bridge_jido_connect_module,
      StubJidoConnectTupleProviderReason
    )

    assert {:error, error2} = JidoConnectBridge.list_files(config, %{})
    assert error2.provider == "{:google_drive, :v2}"
    assert error2.status == 500
  end

  test "capability_snapshot marks webhook capabilities unsupported and watch_changes rejects polling" do
    previous_channels = Application.get_env(:zaq, :channels)
    previous_jido_connect = Application.get_env(:zaq, :jido_connect_bridge_jido_connect_module)
    previous_node_router = Application.get_env(:zaq, :jido_connect_bridge_node_router_module)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{
        bridge: JidoConnectBridge,
        integration: BridgeStubIntegration
      }
    })

    Application.put_env(
      :zaq,
      :jido_connect_bridge_jido_connect_module,
      StubJidoConnectCapabilitySnapshot
    )

    on_exit(fn ->
      BridgeTest.restore_webhook_env(
        previous_channels,
        previous_jido_connect,
        previous_node_router
      )
    end)

    config = BridgeTest.insert_data_source_config(:google_drive)

    assert {:ok, snapshot} = JidoConnectBridge.capability_snapshot(config)
    assert :watch_changes_webhook in snapshot.unsupported
    assert :receive_change_webhook in snapshot.unsupported

    assert {:error, :unsupported} =
             JidoConnectBridge.watch_changes(config, %{"mechanism" => "polling"})
  end

  test "handle_webhook accepts struct deliveries and dispatches created records" do
    previous_channels = Application.get_env(:zaq, :channels)
    previous_jido_connect = Application.get_env(:zaq, :jido_connect_bridge_jido_connect_module)
    previous_node_router = Application.get_env(:zaq, :jido_connect_bridge_node_router_module)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{
        bridge: JidoConnectBridge,
        integration: BridgeStubIntegration,
        webhook_verifier: StructWebhookVerifier
      }
    })

    Application.put_env(
      :zaq,
      :jido_connect_bridge_jido_connect_module,
      StubJidoConnectWebhookCreated
    )

    Application.put_env(:zaq, :jido_connect_bridge_node_router_module, StubWebhookNodeRouter)

    on_exit(fn ->
      BridgeTest.restore_webhook_env(
        previous_channels,
        previous_jido_connect,
        previous_node_router
      )
    end)

    config = BridgeTest.insert_data_source_config(:google_drive)

    assert {:ok, %{accepted: true, job_id: _job_id}} =
             JidoConnectBridge.handle_webhook(config, %{"headers" => %{}, "raw_body" => "{}"})

    assert_received {:data_source_record_changed, request}
    assert request.record.id == "file-1"
    assert request.record.change_type == :created
    assert request.record.lifecycle_state == :active
    assert %DateTime{} = request.record.deleted_at
  end
end

defmodule Zaq.Channels.JidoConnectBridgeCoverageGapsTest do
  use Zaq.DataCase, async: false
  setup {Req.Test, :verify_on_exit!}

  setup do
    previous_catalog = Application.get_env(:zaq, :jido_connect_bridge_catalog_module)

    Application.put_env(
      :zaq,
      :jido_connect_bridge_catalog_module,
      Zaq.Test.Channels.CatalogAdapterStub
    )

    on_exit(fn ->
      if previous_catalog do
        Application.put_env(:zaq, :jido_connect_bridge_catalog_module, previous_catalog)
      else
        Application.delete_env(:zaq, :jido_connect_bridge_catalog_module)
      end
    end)

    :ok
  end

  alias Jido.Connect.Spec
  alias StubIntegration, as: BridgeStubIntegration
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.JidoConnectBridge
  alias Zaq.Engine.Connect
  alias Zaq.Ingestion.Document
  alias Zaq.Repo

  defmodule StubIntegration do
  end

  defmodule StubJidoConnect do
    def actions(_integration) do
      {:ok,
       [
         %{
           id: "stub.files.list",
           resource: :file,
           verb: :list,
           auth_profile: :user,
           auth_profiles: [:user],
           input: [%{name: :fields}, %{name: :page_size}]
         },
         %{
           id: "stub.permissions.list",
           resource: :permission,
           verb: :list,
           auth_profile: :user,
           auth_profiles: [:user],
           input: [%{name: :fields}, %{name: :page_size}]
         }
       ]}
    end

    def invoke(_integration, "stub.files.list", params, opts) do
      send(self(), {:invoke_files, params, opts})

      {:ok,
       %{
         files: [
           %{
             "id" => "f1",
             "name" => "Root Folder",
             "mimeType" => "application/vnd.google-apps.folder",
             "parents" => []
           },
           %{
             "id" => "f2",
             "name" => "Doc 1",
             "mimeType" => "application/pdf",
             "parents" => ["root"],
             "permissions" => [
               %{"id" => "ep1", "type" => "user", "emailAddress" => "owner@example.com"}
             ]
           }
         ]
       }}
    end

    def invoke(_integration, "stub.permissions.list", %{file_id: _file_id}, _opts) do
      {:ok,
       %{
         permissions: [
           %{"id" => "u1", "type" => "user", "emailAddress" => "a@example.com"},
           %{"id" => "u2", "type" => "group", "emailAddress" => "team@example.com"}
         ]
       }}
    end

    def triggers(_integration), do: {:ok, []}
  end

  def insert_data_source_config(provider, attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    base = %{
      name: "cfg-#{provider}-#{unique}",
      provider: to_string(provider),
      kind: "data_source",
      enabled: true,
      settings: %{}
    }

    %ChannelConfig{}
    |> ChannelConfig.changeset(Map.merge(base, attrs))
    |> Repo.insert!()
  end

  def create_credential! do
    {:ok, credential} =
      Connect.create_credential(%{
        name: "cred-#{System.unique_integer([:positive])}",
        provider: "google_drive",
        auth_kind: "oauth2",
        request_format: "bearer",
        user_level: false,
        metadata: %{},
        client_id: "client",
        client_secret: "secret",
        scopes: ["https://www.googleapis.com/auth/drive.metadata.readonly"]
      })

    credential
  end

  def create_active_grant!(credential, resource_id, owner_type \\ "org") do
    {:ok, grant} =
      Connect.issue_grant(%{
        credential_id: credential.id,
        auth_kind: "oauth2",
        resource_type: "data_source",
        resource_id: resource_id,
        owner_type: owner_type,
        owner_id: nil,
        request_format: "bearer",
        metadata: %{},
        status: "active",
        access_token: "access-token",
        refresh_token: "refresh-token",
        scopes: ["https://www.googleapis.com/auth/drive.metadata.readonly"]
      })

    grant
  end

  def restore_webhook_env(previous_channels, previous_jido_connect, previous_node_router) do
    if previous_channels,
      do: Application.put_env(:zaq, :channels, previous_channels),
      else: Application.delete_env(:zaq, :channels)

    if previous_jido_connect,
      do:
        Application.put_env(:zaq, :jido_connect_bridge_jido_connect_module, previous_jido_connect),
      else: Application.delete_env(:zaq, :jido_connect_bridge_jido_connect_module)

    if previous_node_router,
      do:
        Application.put_env(:zaq, :jido_connect_bridge_node_router_module, previous_node_router),
      else: Application.delete_env(:zaq, :jido_connect_bridge_node_router_module)
  end

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
      do:
        {:ok,
         [
           %{
             id: "stub.file.changed",
             kind: :webhook,
             verb: :watch,
             handler: Zaq.Channels.JidoConnectBridgeCoverageGapsTest.StructWebhookVerifier
           }
         ]}
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
      do:
        {:ok,
         [
           %{
             id: "stub.file.changed",
             kind: :webhook,
             verb: :watch,
             handler: Zaq.Channels.JidoConnectBridgeCoverageGapsTest.StructWebhookVerifier
           }
         ]}
  end

  defmodule StubJidoConnectWatchItem do
    def actions(_integration) do
      {:ok,
       [
         %{id: "google.drive.file.watch", resource: :file, verb: :watch, auth_profiles: [:user]},
         %{
           id: "google.drive.collection.watch",
           resource: :collection,
           verb: :watch,
           auth_profiles: [:user]
         },
         %{
           id: "google.drive.collection.changes.list",
           resource: :collection,
           verb: :list,
           auth_profiles: [:user]
         },
         %{
           id: "google.drive.channel.stop",
           resource: :channel,
           verb: :delete,
           auth_profiles: [:user]
         }
       ]}
    end

    def invoke(_integration, "google.drive.file.watch", params, _opts) do
      send(self(), {:watch_file, params})

      {:ok,
       %{
         channel: %{
           "id" => params.channel_id,
           "resource_id" => "resource-1",
           "expiration" => "123"
         }
       }}
    end

    def invoke(_integration, "google.drive.collection.watch", params, _opts) do
      send(self(), {:watch_collection, params})

      {:ok,
       %{
         channel: %{
           "id" => params.channel_id,
           "resource_id" => "collection-resource-1",
           "expiration" => "123"
         },
         checkpoint: "checkpoint-1",
         collection_id: Map.get(params, :collection_id),
         provider: "google_drive"
       }}
    end

    def invoke(_integration, "google.drive.collection.changes.list", params, _opts) do
      send(self(), {:list_collection_changes, params})

      {:ok,
       %{
         checkpoint: "checkpoint-2",
         has_more?: false,
         signals: [
           %{
             provider_record_id: "changed-file-1",
             change_type: :updated,
             removed?: false,
             record: %{
               id: "changed-file-1",
               name: "Changed file",
               mime_type: "application/pdf",
               parents: List.wrap(Map.get(params, :collection_id)),
               web_url: "https://drive.example/changed-file-1"
             }
           },
           %{
             provider_record_id: "removed-file-1",
             change_type: :deleted,
             removed?: true
           }
         ]
       }}
    end

    def invoke(_integration, "google.drive.channel.stop", params, _opts) do
      send(self(), {:stop_channel, params})
      {:ok, %{result: %{}}}
    end
  end

  defmodule StructWebhookVerifier do
    defstruct [:normalized_signal]

    def normalize_signal(_payload) do
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
    def dispatch(%{opts: [action: :ingest_records]} = event) do
      send(self(), {:ingest_records, event.request})
      %{event | response: :ok}
    end

    def dispatch(%{opts: [action: :resolve_data_source_watch_channel]} = event) do
      %{
        event
        | response:
            {:ok, Process.get(:stub_watch_channel) || default_watch_channel(event.request)}
      }
    end

    def dispatch(%{opts: [action: :process_data_source_watch_changes]} = event) do
      send(self(), {:process_data_source_watch_changes, event.request})
      send(self(), {:ingest_records, event.request})
      %{event | response: :ok}
    end

    def dispatch(%{opts: [action: :connect_get_active_grant]} = event),
      do: %{event | response: Process.get(:stub_runtime_grant)}

    def dispatch(%{opts: [action: :connect_fetch_credential]} = event),
      do: %{event | response: {:ok, Process.get(:stub_runtime_credential)}}

    def dispatch(%{opts: [action: :connect_oauth_redirect_uri_for]} = event),
      do: %{event | response: nil}

    defp default_watch_channel(request) do
      collection? = String.contains?(to_string(Map.get(request, :channel_id)), "collection")

      %{
        id: 1,
        provider: Map.get(request, :provider),
        config_id: Map.get(request, :config_id),
        target_kind: if(collection?, do: "collection", else: "file"),
        target_provider_id: if(collection?, do: "folder-1", else: "file-1"),
        target_source:
          if(collection?,
            do: "data_source/google_drive/1/folder-1",
            else: "data_source/google_drive/1/file-1"
          ),
        checkpoint: if(collection?, do: "checkpoint-1", else: nil)
      }
    end
  end

  defmodule StubRuntimeNodeRouter do
    def dispatch(%{opts: [action: :connect_get_active_grant]} = event) do
      %{event | response: Process.get(:stub_runtime_grant)}
    end

    def dispatch(%{opts: [action: :connect_fetch_credential]} = event) do
      %{event | response: {:ok, Process.get(:stub_runtime_credential)}}
    end

    def dispatch(%{opts: [action: :upsert_data_source_watch_channel]} = event) do
      send(self(), {:upsert_data_source_watch_channel, event.request})
      %{event | response: {:ok, Map.put(event.request, :id, 1)}}
    end

    def dispatch(%{opts: [action: :resolve_data_source_watch_channel]} = event) do
      case Process.get(:stub_watch_channel) do
        nil -> %{event | response: {:error, :watch_channel_not_found}}
        watch_channel -> %{event | response: {:ok, watch_channel}}
      end
    end

    def dispatch(%{opts: [action: :mark_data_source_watch_channel_stopped]} = event) do
      %{event | response: {:ok, %{id: event.request.watch_channel_id, status: "stopped"}}}
    end
  end

  defmodule StubJidoConnectTriggersError do
    def actions(_integration),
      do: {:ok, [%{id: "stub.files.list", resource: :file, verb: :list, auth_profiles: [:user]}]}

    def triggers(_integration), do: {:error, :boom}
  end

  defmodule StubJidoConnectNoWebhookTrigger do
    def actions(_integration),
      do: {:ok, [%{id: "stub.files.list", resource: :file, verb: :list, auth_profiles: [:user]}]}

    def triggers(_integration),
      do: {:ok, [%{id: "stub.file.created", kind: :webhook, verb: :create}]}
  end

  defmodule StubJidoConnectScopesAndFields do
    def actions(_integration) do
      {:ok,
       [
         %{
           id: "stub.files.list",
           resource: :file,
           verb: :list,
           auth_profiles: [:user],
           input: [%{name: :fields}, %{name: :page_size}],
           scopes: [:read, " ", "read", nil, :write]
         },
         %{
           id: "stub.permissions.list",
           resource: :permission,
           verb: :list,
           auth_profiles: [:user],
           input: [%{name: :fields}, %{name: :page_size}],
           scopes: ["perm.read", "", "perm.read", :perm_write]
         }
       ]}
    end

    def invoke(_integration, "stub.files.list", params, opts) do
      send(self(), {:invoke_files, params, opts})

      {:ok,
       %{
         files: [
           %{"id" => "f1", "name" => "Doc", "mimeType" => "application/pdf"}
         ]
       }}
    end

    def invoke(_integration, "stub.permissions.list", %{file_id: _file_id}, _opts) do
      {:ok,
       %{
         permissions: [
           %{"id" => "p1", "type" => "user", "emailAddress" => "a@example.com"},
           %{"id" => " ", "emailAddress" => "", "domain" => "", "type" => ""}
         ]
       }}
    end

    def triggers(_integration), do: {:ok, []}
  end

  defmodule StubOAuthIntegrationWithProfile do
    def integration do
      Spec.new!(%{
        id: :stub_oauth_integration_with_profile,
        name: "Stub OAuth Integration With Profile",
        auth_profiles: [
          %{
            id: :stub_oauth,
            kind: :oauth2,
            owner: :user,
            subject: :stub,
            authorize_url: "https://auth.example/authorize",
            token_url: "https://auth.example/token"
          }
        ],
        actions: [],
        triggers: [
          %{
            id: "stub.file.changed",
            name: :stub_file_changed,
            kind: :webhook,
            resource: :file,
            verb: :watch,
            data_classification: :workspace_metadata,
            label: "Stub file changed",
            auth_profile: :stub_oauth,
            auth_profiles: [:stub_oauth],
            config_schema: %{},
            signal_schema: %{},
            verification: %{kind: :signature},
            handler: StubIntegration
          }
        ]
      })
    end
  end

  defmodule StubOAuthIntegrationNoProfile do
    def integration do
      Spec.new!(%{
        id: :stub_oauth_integration_no_profile,
        name: "Stub OAuth Integration No Profile",
        auth_profiles: [
          %{
            id: :stub_user,
            kind: :user,
            owner: :user,
            subject: :stub
          }
        ],
        actions: [],
        triggers: []
      })
    end
  end

  defmodule StubOAuthIntegrationInvalid do
    def integration do
      %{unexpected: true}
    end
  end

  defmodule StubOAuthNodeRouterSuccess do
    def dispatch(%{opts: [action: :connect_fetch_credential], request: %{credential_id: id}}) do
      %{response: {:ok, %{id: id, client_id: "client", client_secret: "secret", scopes: []}}}
    end

    def dispatch(%{
          opts: [action: :connect_oauth_redirect_uri_for],
          request: %{provider: provider}
        }) do
      %{response: "https://zaq.example/channels/oauth2/#{provider}/redirect"}
    end
  end

  defmodule StubObanInsertError do
    def insert(_job), do: {:error, :boom}
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
      restore_webhook_env(
        previous_channels,
        previous_jido_connect,
        previous_node_router
      )
    end)

    config = insert_data_source_config(:google_drive)

    credential = create_credential!()
    _grant = create_active_grant!(credential, config.id)

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

    config = insert_data_source_config(:google_drive)
    credential = create_credential!()
    _grant = create_active_grant!(credential, config.id)

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
      restore_webhook_env(
        previous_channels,
        previous_jido_connect,
        previous_node_router
      )
    end)

    config = insert_data_source_config(:google_drive)

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
      restore_webhook_env(
        previous_channels,
        previous_jido_connect,
        previous_node_router
      )
    end)

    config = insert_data_source_config(:google_drive)

    assert {:ok, %{accepted: true, job_id: _job_id}} =
             JidoConnectBridge.handle_webhook(config, %{"headers" => %{}, "raw_body" => "{}"})

    assert_received {:ingest_records, request}
    assert [record] = request.records
    assert record.id == "file-1"
    assert record.change_type == :created
    assert record.lifecycle_state == :active
    assert record.attributes["provider"] == "google_drive"
    assert record.attributes["config_id"] == to_string(config.id)
    assert %DateTime{} = record.deleted_at
  end

  test "watch_item ensures config-level collection watch and unwatch can stop provider channel" do
    previous_channels = Application.get_env(:zaq, :channels)
    previous_jido_connect = Application.get_env(:zaq, :jido_connect_bridge_jido_connect_module)
    previous_node_router = Application.get_env(:zaq, :jido_connect_bridge_node_router_module)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: JidoConnectBridge, integration: BridgeStubIntegration}
    })

    Application.put_env(:zaq, :jido_connect_bridge_jido_connect_module, StubJidoConnectWatchItem)
    Application.put_env(:zaq, :jido_connect_bridge_node_router_module, StubRuntimeNodeRouter)

    on_exit(fn ->
      restore_webhook_env(previous_channels, previous_jido_connect, previous_node_router)
    end)

    config = insert_data_source_config(:google_drive)
    credential = create_credential!()
    grant = create_active_grant!(credential, to_string(config.id))
    Process.put(:stub_runtime_grant, grant)
    Process.put(:stub_runtime_credential, credential)
    config_watch_source = "data_source/google_drive/#{config.id}"

    assert {:ok,
            %{
              status: "watched",
              channel_id: "channel-1",
              resource_id: "collection-resource-1",
              checkpoint: "checkpoint-1",
              collection_id: nil
            }} =
             JidoConnectBridge.watch_item(config, %{
               "file_id" => "file-1",
               "channel_id" => "channel-1",
               "webhook_url" => "https://example.test/channels/webhook/data_source/google_drive"
             })

    assert_received {:watch_collection, watch_params}
    refute Map.has_key?(watch_params, :collection_id)
    assert watch_params.channel_id == "channel-1"
    assert is_integer(watch_params.expiration_ms)

    min_expiration_ms =
      DateTime.utc_now()
      |> DateTime.add(29 * 24 * 60 * 60, :second)
      |> DateTime.to_unix(:millisecond)

    assert watch_params.expiration_ms > min_expiration_ms

    assert watch_params.address ==
             "https://example.test/channels/webhook/data_source/google_drive"

    assert_received {:upsert_data_source_watch_channel,
                     %{
                       target_source: ^config_watch_source,
                       target_provider_id: "changes",
                       target_kind: "collection",
                       expiration_at: "123",
                       metadata: %{"watch" => watch_metadata}
                     }}

    refute Map.has_key?(watch_metadata, "address")

    assert {:ok, %{status: "unwatched", channel_id: "channel-1", resource_id: "resource-1"}} =
             JidoConnectBridge.unwatch_item(config, %{
               "channel_id" => "channel-1",
               "resource_id" => "resource-1"
             })

    assert_received {:stop_channel, %{channel_id: "channel-1", resource_id: "resource-1"}}
  end

  test "folder watch reuses config-level collection watch action and stores checkpoint in Engine" do
    previous_channels = Application.get_env(:zaq, :channels)
    previous_jido_connect = Application.get_env(:zaq, :jido_connect_bridge_jido_connect_module)
    previous_node_router = Application.get_env(:zaq, :jido_connect_bridge_node_router_module)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: JidoConnectBridge, integration: BridgeStubIntegration}
    })

    Application.put_env(:zaq, :jido_connect_bridge_jido_connect_module, StubJidoConnectWatchItem)
    Application.put_env(:zaq, :jido_connect_bridge_node_router_module, StubRuntimeNodeRouter)

    on_exit(fn ->
      restore_webhook_env(previous_channels, previous_jido_connect, previous_node_router)
    end)

    config = insert_data_source_config(:google_drive)
    credential = create_credential!()
    grant = create_active_grant!(credential, to_string(config.id))
    Process.put(:stub_runtime_grant, grant)
    Process.put(:stub_runtime_credential, credential)
    config_watch_source = "data_source/google_drive/#{config.id}"

    assert {:ok,
            %{
              status: "watched",
              channel_id: "collection-channel-1",
              resource_id: "collection-resource-1",
              collection_id: nil,
              checkpoint: "checkpoint-1",
              metadata: %{
                "watch" => %{
                  "kind" => "collection",
                  "collection_id" => nil,
                  "checkpoint" => "checkpoint-1"
                }
              }
            }} =
             JidoConnectBridge.watch_item(config, %{
               "file_id" => "folder-1",
               "kind" => "folder",
               "channel_id" => "collection-channel-1",
               "webhook_url" => "https://example.test/channels/webhook/data_source/google_drive"
             })

    assert_received {:watch_collection, watch_params}
    refute Map.has_key?(watch_params, :collection_id)
    assert watch_params.channel_id == "collection-channel-1"
    assert is_integer(watch_params.expiration_ms)

    assert watch_params.address ==
             "https://example.test/channels/webhook/data_source/google_drive"

    assert_received {:upsert_data_source_watch_channel,
                     %{
                       target_source: ^config_watch_source,
                       target_provider_id: "changes",
                       target_kind: "collection"
                     }}
  end

  test "watch_item reuses an existing changes watcher without provider registration" do
    previous_channels = Application.get_env(:zaq, :channels)
    previous_jido_connect = Application.get_env(:zaq, :jido_connect_bridge_jido_connect_module)
    previous_node_router = Application.get_env(:zaq, :jido_connect_bridge_node_router_module)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: JidoConnectBridge, integration: BridgeStubIntegration}
    })

    Application.put_env(:zaq, :jido_connect_bridge_jido_connect_module, StubJidoConnectWatchItem)
    Application.put_env(:zaq, :jido_connect_bridge_node_router_module, StubRuntimeNodeRouter)

    on_exit(fn ->
      restore_webhook_env(previous_channels, previous_jido_connect, previous_node_router)
    end)

    config = insert_data_source_config(:google_drive)

    Process.put(:stub_watch_channel, %{
      id: 7,
      channel_id: "existing-channel",
      resource_id: "existing-resource",
      checkpoint: "existing-checkpoint",
      target_kind: "collection",
      target_provider_id: "changes",
      target_source: "data_source/google_drive/#{config.id}"
    })

    assert {:ok,
            %{
              status: "watched",
              channel_id: "existing-channel",
              resource_id: "existing-resource",
              checkpoint: "existing-checkpoint"
            }} =
             JidoConnectBridge.watch_item(config, %{
               "file_id" => "file-1",
               "webhook_url" => "https://example.test/channels/webhook/data_source/google_drive"
             })

    refute_received {:watch_collection, _params}
  end

  test "collection webhook consumes collection changes and updates checkpoint" do
    previous_channels = Application.get_env(:zaq, :channels)
    previous_jido_connect = Application.get_env(:zaq, :jido_connect_bridge_jido_connect_module)
    previous_node_router = Application.get_env(:zaq, :jido_connect_bridge_node_router_module)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: JidoConnectBridge, integration: BridgeStubIntegration}
    })

    Application.put_env(:zaq, :jido_connect_bridge_jido_connect_module, StubJidoConnectWatchItem)
    Application.put_env(:zaq, :jido_connect_bridge_node_router_module, StubWebhookNodeRouter)

    on_exit(fn ->
      restore_webhook_env(previous_channels, previous_jido_connect, previous_node_router)
    end)

    config = insert_data_source_config(:google_drive)
    credential = create_credential!()
    grant = create_active_grant!(credential, to_string(config.id))
    Process.put(:stub_runtime_grant, grant)
    Process.put(:stub_runtime_credential, credential)

    {:ok, _watched_folder} =
      Document.insert_new(%{
        source: "data_source/google_drive/#{config.id}/folder-1",
        metadata: %{
          "entry_type" => "folder",
          "watch" => %{
            "provider" => "google_drive",
            "kind" => "collection",
            "collection_id" => "folder-1",
            "checkpoint" => "checkpoint-1",
            "channel_id" => "collection-channel-1",
            "resource_id" => "collection-resource-1"
          }
        },
        watch_status: "watched"
      })

    {:ok, _removed_doc} =
      Document.insert_new(%{
        source: "data_source/google_drive/#{config.id}/removed-file-1",
        content: "old content"
      })

    assert :ok =
             JidoConnectBridge.process_verified_webhook_job(%{
               "config_id" => config.id,
               "provider" => "google_drive",
               "trigger_id" => "google.drive.collection.changes.push",
               "payload" => %{"headers" => %{}},
               "delivery" => %{
                 "normalized_signal" => %{
                   "channel_id" => "collection-channel-1",
                   "resource_id" => "collection-resource-1"
                 }
               }
             })

    assert_received {:list_collection_changes,
                     %{checkpoint: "checkpoint-1", collection_id: "folder-1"}}

    assert_received {:process_data_source_watch_changes, request}
    assert request.watch_channel_id == 1
    assert request.next_checkpoint == "checkpoint-2"

    assert [%{provider_record_id: "changed-file-1"}, %{provider_record_id: "removed-file-1"}] =
             request.signals
  end

  test "global changes webhook omits nil collection_id when listing changes" do
    previous_channels = Application.get_env(:zaq, :channels)
    previous_jido_connect = Application.get_env(:zaq, :jido_connect_bridge_jido_connect_module)
    previous_node_router = Application.get_env(:zaq, :jido_connect_bridge_node_router_module)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: JidoConnectBridge, integration: BridgeStubIntegration}
    })

    Application.put_env(:zaq, :jido_connect_bridge_jido_connect_module, StubJidoConnectWatchItem)
    Application.put_env(:zaq, :jido_connect_bridge_node_router_module, StubWebhookNodeRouter)

    on_exit(fn ->
      restore_webhook_env(previous_channels, previous_jido_connect, previous_node_router)
    end)

    config = insert_data_source_config(:google_drive)
    credential = create_credential!()
    grant = create_active_grant!(credential, to_string(config.id))
    Process.put(:stub_runtime_grant, grant)
    Process.put(:stub_runtime_credential, credential)

    Process.put(:stub_watch_channel, %{
      id: 1,
      provider: "google_drive",
      config_id: config.id,
      channel_id: "global-channel-1",
      resource_id: "global-resource-1",
      target_kind: "collection",
      target_provider_id: "changes",
      target_source: "data_source/google_drive/#{config.id}",
      checkpoint: "checkpoint-1"
    })

    assert :ok =
             JidoConnectBridge.process_verified_webhook_job(%{
               "config_id" => config.id,
               "provider" => "google_drive",
               "trigger_id" => "google.drive.collection.changes.push",
               "payload" => %{"headers" => %{}},
               "delivery" => %{
                 "normalized_signal" => %{
                   "channel_id" => "global-channel-1",
                   "resource_id" => "global-resource-1"
                 }
               }
             })

    assert_received {:list_collection_changes, %{checkpoint: "checkpoint-1"} = params}
    refute Map.has_key?(params, :collection_id)
  end

  test "list_files leaves permission projection untouched when config provider is missing" do
    previous_node_router = Application.get_env(:zaq, :jido_connect_bridge_node_router_module)

    Application.put_env(:zaq, :jido_connect_bridge_node_router_module, StubRuntimeNodeRouter)

    on_exit(fn ->
      if previous_node_router,
        do:
          Application.put_env(
            :zaq,
            :jido_connect_bridge_node_router_module,
            previous_node_router
          ),
        else: Application.delete_env(:zaq, :jido_connect_bridge_node_router_module)
    end)

    credential = create_credential!()
    grant = create_active_grant!(credential, 123)
    Process.put(:stub_runtime_credential, credential)
    Process.put(:stub_runtime_grant, grant)

    assert {:error, _reason} =
             JidoConnectBridge.list_files(%{id: 123, provider: :google_drive}, %{
               include_permissions: true
             })
  end

  describe "coverage gaps" do
    test "process_verified_webhook_job validates webhook args and cancel paths" do
      config =
        insert_data_source_config(:google_drive, %{
          settings: %{"connect" => %{"credential_id" => "cred-1"}}
        })

      assert {:cancel, :provider_mismatch} =
               JidoConnectBridge.process_verified_webhook_job(%{
                 "config_id" => config.id,
                 "provider" => "other"
               })

      assert {:cancel, :missing_config} =
               JidoConnectBridge.process_verified_webhook_job(%{"provider" => "google_drive"})

      assert {:cancel, :config_not_found} =
               JidoConnectBridge.process_verified_webhook_job(%{
                 "config_id" => -1,
                 "provider" => "google_drive"
               })

      assert {:cancel, :missing_trigger_id} =
               JidoConnectBridge.process_verified_webhook_job(%{
                 "config_id" => config.id,
                 "provider" => "google_drive",
                 "payload" => %{},
                 "delivery" => %{}
               })

      assert {:cancel, :missing_payload} =
               JidoConnectBridge.process_verified_webhook_job(%{
                 "config_id" => config.id,
                 "provider" => "google_drive",
                 "trigger_id" => "trigger-1",
                 "delivery" => %{}
               })

      assert {:cancel, :missing_delivery} =
               JidoConnectBridge.process_verified_webhook_job(%{
                 "config_id" => config.id,
                 "provider" => "google_drive",
                 "trigger_id" => "trigger-1",
                 "payload" => %{}
               })

      assert_raise FunctionClauseError, fn ->
        JidoConnectBridge.process_verified_webhook_job(:not_a_map)
      end
    end

    test "setup_listener rejects webhook providers without a matching watch trigger" do
      previous_channels = Application.get_env(:zaq, :channels)
      previous_jido_connect = Application.get_env(:zaq, :jido_connect_bridge_jido_connect_module)

      Application.put_env(:zaq, :channels, %{
        google_drive: %{bridge: JidoConnectBridge, integration: StubOAuthIntegrationWithProfile}
      })

      Application.put_env(
        :zaq,
        :jido_connect_bridge_jido_connect_module,
        StubJidoConnectNoWebhookTrigger
      )

      on_exit(fn ->
        if previous_channels,
          do: Application.put_env(:zaq, :channels, previous_channels),
          else: Application.delete_env(:zaq, :channels)

        if previous_jido_connect,
          do:
            Application.put_env(
              :zaq,
              :jido_connect_bridge_jido_connect_module,
              previous_jido_connect
            ),
          else: Application.delete_env(:zaq, :jido_connect_bridge_jido_connect_module)
      end)

      config =
        insert_data_source_config(:google_drive, %{
          settings: %{"connect" => %{"credential_id" => "cred-1"}}
        })

      assert {:error, :unsupported} = JidoConnectBridge.setup_listener(config, %{})
    end

    test "process_verified_webhook_job handles deleted webhook deliveries" do
      previous_node_router = Application.get_env(:zaq, :jido_connect_bridge_node_router_module)

      Application.put_env(:zaq, :jido_connect_bridge_node_router_module, StubWebhookNodeRouter)

      on_exit(fn ->
        if previous_node_router,
          do:
            Application.put_env(
              :zaq,
              :jido_connect_bridge_node_router_module,
              previous_node_router
            ),
          else: Application.delete_env(:zaq, :jido_connect_bridge_node_router_module)
      end)

      config =
        insert_data_source_config(:google_drive, %{
          settings: %{"connect" => %{"credential_id" => "cred-1"}}
        })

      assert :ok =
               JidoConnectBridge.process_verified_webhook_job(%{
                 "config_id" => config.id,
                 "provider" => "google_drive",
                 "trigger_id" => "trigger-1",
                 "payload" => %{"headers" => %{}, "raw_body" => "{}"},
                 "delivery" => %{
                   "normalized_signal" => %{
                     "resource_id" => "file-1",
                     "removed" => true,
                     "time" => "not-an-iso8601-timestamp"
                   }
                 }
               })

      assert_received {:ingest_records, request}
      assert [record] = request.records
      assert record.id == "file-1"
      assert record.change_type == :deleted
      assert record.lifecycle_state == :deleted
      assert is_nil(record.deleted_at)
    end

    test "process_verified_webhook_job handles deleted webhook deliveries with atom keys" do
      previous_node_router = Application.get_env(:zaq, :jido_connect_bridge_node_router_module)

      Application.put_env(:zaq, :jido_connect_bridge_node_router_module, StubWebhookNodeRouter)

      on_exit(fn ->
        if previous_node_router,
          do:
            Application.put_env(
              :zaq,
              :jido_connect_bridge_node_router_module,
              previous_node_router
            ),
          else: Application.delete_env(:zaq, :jido_connect_bridge_node_router_module)
      end)

      config =
        insert_data_source_config(:google_drive, %{
          settings: %{"connect" => %{"credential_id" => "cred-1"}}
        })

      assert :ok =
               JidoConnectBridge.process_verified_webhook_job(%{
                 "config_id" => config.id,
                 "provider" => "google_drive",
                 "trigger_id" => "trigger-1",
                 "payload" => %{"headers" => %{}, "raw_body" => "{}"},
                 "delivery" => %{
                   normalized_signal: %{
                     resource_id: "file-1",
                     removed: true,
                     time: "2026-05-17T00:00:00Z"
                   }
                 }
               })
    end

    test "oauth_default_scopes normalizes mixed scope values from provider requirements" do
      previous_channels = Application.get_env(:zaq, :channels)
      previous_jido_connect = Application.get_env(:zaq, :jido_connect_bridge_jido_connect_module)

      Application.put_env(:zaq, :channels, %{
        google_drive: %{
          bridge: JidoConnectBridge,
          integration: StubOAuthIntegrationWithProfile
        }
      })

      Application.put_env(
        :zaq,
        :jido_connect_bridge_jido_connect_module,
        StubJidoConnectScopesAndFields
      )

      on_exit(fn ->
        if previous_channels,
          do: Application.put_env(:zaq, :channels, previous_channels),
          else: Application.delete_env(:zaq, :channels)

        if previous_jido_connect,
          do:
            Application.put_env(
              :zaq,
              :jido_connect_bridge_jido_connect_module,
              previous_jido_connect
            ),
          else: Application.delete_env(:zaq, :jido_connect_bridge_jido_connect_module)
      end)

      assert {:ok, scopes} = JidoConnectBridge.oauth_default_scopes(%{provider: "google_drive"})
      assert Enum.sort(scopes) == ["perm.read", "perm_write", "read", "write"]
    end

    test "oauth_authorize_url returns unsupported for unknown providers" do
      previous_channels = Application.get_env(:zaq, :channels)
      previous_node_router = Application.get_env(:zaq, :jido_connect_bridge_node_router_module)

      Application.put_env(
        :zaq,
        :jido_connect_bridge_node_router_module,
        StubOAuthNodeRouterSuccess
      )

      on_exit(fn ->
        if previous_channels,
          do: Application.put_env(:zaq, :channels, previous_channels),
          else: Application.delete_env(:zaq, :channels)

        if previous_node_router,
          do:
            Application.put_env(
              :zaq,
              :jido_connect_bridge_node_router_module,
              previous_node_router
            ),
          else: Application.delete_env(:zaq, :jido_connect_bridge_node_router_module)
      end)

      config = %{
        provider: "unknown_provider",
        settings: %{"connect" => %{"credential_id" => "cred-1"}}
      }

      assert {:error, :unsupported} =
               JidoConnectBridge.oauth_authorize_url(config, %{"state" => "state-123"})
    end

    test "oauth_exchange_code normalizes token payloads" do
      previous_channels = Application.get_env(:zaq, :channels)
      previous_node_router = Application.get_env(:zaq, :jido_connect_bridge_node_router_module)
      previous_req_options = Application.get_env(:jido_connect_google, :google_oauth_req_options)

      Application.put_env(:zaq, :channels, %{
        google_drive: %{bridge: JidoConnectBridge, integration: StubOAuthIntegrationWithProfile}
      })

      Application.put_env(
        :zaq,
        :jido_connect_bridge_node_router_module,
        StubOAuthNodeRouterSuccess
      )

      Application.put_env(:jido_connect_google, :google_oauth_req_options,
        plug: {Req.Test, __MODULE__}
      )

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          access_token: "access-token",
          refresh_token: "refresh-token",
          expires_in: 3600,
          scope: "read write"
        })
      end)

      on_exit(fn ->
        if previous_channels,
          do: Application.put_env(:zaq, :channels, previous_channels),
          else: Application.delete_env(:zaq, :channels)

        if previous_node_router,
          do:
            Application.put_env(
              :zaq,
              :jido_connect_bridge_node_router_module,
              previous_node_router
            ),
          else: Application.delete_env(:zaq, :jido_connect_bridge_node_router_module)

        if previous_req_options,
          do:
            Application.put_env(
              :jido_connect_google,
              :google_oauth_req_options,
              previous_req_options
            ),
          else: Application.delete_env(:jido_connect_google, :google_oauth_req_options)
      end)

      {:ok, credential} =
        Connect.create_credential(%{
          name: "cred-#{System.unique_integer([:positive])}",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          user_level: false,
          metadata: %{},
          client_id: "client",
          client_secret: "secret",
          scopes: []
        })

      config =
        insert_data_source_config(:google_drive, %{
          settings: %{"connect" => %{"credential_id" => Integer.to_string(credential.id)}}
        })

      assert {:ok, token} =
               JidoConnectBridge.oauth_exchange_code(config, %{"code" => "auth-code"})

      assert token.access_token == "access-token"
      assert token.refresh_token == "refresh-token"
      assert token.scopes == ["read", "write"]
    end

    test "list_files leaves permission fields unchanged for non-google providers" do
      previous_channels = Application.get_env(:zaq, :channels)
      previous_jido_connect = Application.get_env(:zaq, :jido_connect_bridge_jido_connect_module)
      previous_node_router = Application.get_env(:zaq, :jido_connect_bridge_node_router_module)

      Application.put_env(:zaq, :channels, %{
        sharepoint: %{bridge: JidoConnectBridge, integration: StubOAuthIntegrationWithProfile}
      })

      Application.put_env(
        :zaq,
        :jido_connect_bridge_jido_connect_module,
        StubJidoConnectScopesAndFields
      )

      Application.put_env(:zaq, :jido_connect_bridge_node_router_module, StubRuntimeNodeRouter)

      on_exit(fn ->
        if previous_channels,
          do: Application.put_env(:zaq, :channels, previous_channels),
          else: Application.delete_env(:zaq, :channels)

        if previous_jido_connect,
          do:
            Application.put_env(
              :zaq,
              :jido_connect_bridge_jido_connect_module,
              previous_jido_connect
            ),
          else: Application.delete_env(:zaq, :jido_connect_bridge_jido_connect_module)

        if previous_node_router,
          do:
            Application.put_env(
              :zaq,
              :jido_connect_bridge_node_router_module,
              previous_node_router
            ),
          else: Application.delete_env(:zaq, :jido_connect_bridge_node_router_module)
      end)

      {:ok, credential} =
        Connect.create_credential(%{
          name: "cred-sharepoint-#{System.unique_integer([:positive])}",
          provider: "sharepoint",
          auth_kind: "oauth2",
          request_format: "bearer",
          user_level: false,
          metadata: %{},
          client_id: "client",
          client_secret: "secret",
          scopes: []
        })

      grant = create_active_grant!(credential, 456, "user")
      Process.put(:stub_runtime_credential, credential)
      Process.put(:stub_runtime_grant, grant)

      config = insert_data_source_config(:sharepoint)

      assert {:ok, _page} =
               JidoConnectBridge.list_files(config, %{
                 include_permissions: true,
                 fields: "id,name"
               })

      assert_received {:invoke_files, params, _opts}
      assert params[:fields] == "id,name"
      assert params["fields"] in [nil, "id,name"]
    end

    test "channel_stats counts blank principals only once" do
      previous_channels = Application.get_env(:zaq, :channels)
      previous_jido_connect = Application.get_env(:zaq, :jido_connect_bridge_jido_connect_module)
      previous_node_router = Application.get_env(:zaq, :jido_connect_bridge_node_router_module)

      Application.put_env(:zaq, :channels, %{
        google_drive: %{bridge: JidoConnectBridge, integration: StubOAuthIntegrationWithProfile}
      })

      Application.put_env(
        :zaq,
        :jido_connect_bridge_jido_connect_module,
        StubJidoConnectScopesAndFields
      )

      Application.put_env(:zaq, :jido_connect_bridge_node_router_module, StubRuntimeNodeRouter)

      on_exit(fn ->
        if previous_channels,
          do: Application.put_env(:zaq, :channels, previous_channels),
          else: Application.delete_env(:zaq, :channels)

        if previous_jido_connect,
          do:
            Application.put_env(
              :zaq,
              :jido_connect_bridge_jido_connect_module,
              previous_jido_connect
            ),
          else: Application.delete_env(:zaq, :jido_connect_bridge_jido_connect_module)

        if previous_node_router,
          do:
            Application.put_env(
              :zaq,
              :jido_connect_bridge_node_router_module,
              previous_node_router
            ),
          else: Application.delete_env(:zaq, :jido_connect_bridge_node_router_module)
      end)

      credential = create_credential!()
      _grant = create_active_grant!(credential, 777)
      Process.put(:stub_runtime_credential, credential)
      Process.put(:stub_runtime_grant, create_active_grant!(credential, 777))
      config = insert_data_source_config(:google_drive)

      assert {:ok, stats} = JidoConnectBridge.channel_stats(config, %{})
      assert stats.principals_count == 1
    end

    test "setup_listener returns unsupported when webhook trigger lookup fails" do
      previous_channels = Application.get_env(:zaq, :channels)
      previous_jido_connect = Application.get_env(:zaq, :jido_connect_bridge_jido_connect_module)
      previous_node_router = Application.get_env(:zaq, :jido_connect_bridge_node_router_module)

      Application.put_env(:zaq, :channels, %{
        google_drive: %{bridge: JidoConnectBridge, integration: BridgeStubIntegration}
      })

      Application.put_env(
        :zaq,
        :jido_connect_bridge_jido_connect_module,
        StubJidoConnectTriggersError
      )

      on_exit(fn ->
        restore_webhook_env(
          previous_channels,
          previous_jido_connect,
          previous_node_router
        )
      end)

      config = insert_data_source_config(:google_drive)

      assert {:error, :unsupported} = JidoConnectBridge.setup_listener(config, %{})
    end

    test "handle_webhook reports enqueue failures" do
      previous_channels = Application.get_env(:zaq, :channels)
      previous_jido_connect = Application.get_env(:zaq, :jido_connect_bridge_jido_connect_module)
      previous_oban = Application.get_env(:zaq, :jido_connect_bridge_oban_module)
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

      Application.put_env(:zaq, :jido_connect_bridge_oban_module, StubObanInsertError)
      Application.put_env(:zaq, :jido_connect_bridge_node_router_module, StubWebhookNodeRouter)

      on_exit(fn ->
        restore_webhook_env(
          previous_channels,
          previous_jido_connect,
          previous_node_router
        )

        if previous_oban,
          do: Application.put_env(:zaq, :jido_connect_bridge_oban_module, previous_oban),
          else: Application.delete_env(:zaq, :jido_connect_bridge_oban_module)
      end)

      config = insert_data_source_config(:google_drive)

      assert {:error, {:webhook_enqueue_failed, :boom}} =
               JidoConnectBridge.handle_webhook(config, %{"headers" => %{}, "raw_body" => "{}"})
    end

    test "handle_webhook rejects webhook providers without a matching trigger" do
      previous_channels = Application.get_env(:zaq, :channels)
      previous_jido_connect = Application.get_env(:zaq, :jido_connect_bridge_jido_connect_module)

      Application.put_env(:zaq, :channels, %{
        google_drive: %{bridge: JidoConnectBridge, integration: StubOAuthIntegrationWithProfile}
      })

      Application.put_env(
        :zaq,
        :jido_connect_bridge_jido_connect_module,
        StubJidoConnectNoWebhookTrigger
      )

      on_exit(fn ->
        if previous_channels,
          do: Application.put_env(:zaq, :channels, previous_channels),
          else: Application.delete_env(:zaq, :channels)

        if previous_jido_connect,
          do:
            Application.put_env(
              :zaq,
              :jido_connect_bridge_jido_connect_module,
              previous_jido_connect
            ),
          else: Application.delete_env(:zaq, :jido_connect_bridge_jido_connect_module)
      end)

      config = insert_data_source_config(:google_drive)

      assert {:error, :unsupported} =
               JidoConnectBridge.handle_webhook(config, %{"headers" => %{}, "raw_body" => "{}"})
    end

    test "list_files leaves permission params untouched for atom and non-google providers" do
      previous_channels = Application.get_env(:zaq, :channels)
      previous_jido_connect = Application.get_env(:zaq, :jido_connect_bridge_jido_connect_module)
      previous_node_router = Application.get_env(:zaq, :jido_connect_bridge_node_router_module)

      Application.put_env(:zaq, :channels, %{
        google_drive: %{bridge: JidoConnectBridge, integration: BridgeStubIntegration},
        sharepoint: %{bridge: JidoConnectBridge, integration: BridgeStubIntegration}
      })

      Application.put_env(
        :zaq,
        :jido_connect_bridge_jido_connect_module,
        StubJidoConnect
      )

      Application.put_env(:zaq, :jido_connect_bridge_node_router_module, StubRuntimeNodeRouter)

      on_exit(fn ->
        restore_webhook_env(
          previous_channels,
          previous_jido_connect,
          previous_node_router
        )
      end)

      atom_credential = create_credential!()
      atom_grant = create_active_grant!(atom_credential, 123, "user")
      Process.put(:stub_runtime_credential, atom_credential)
      Process.put(:stub_runtime_grant, atom_grant)

      atom_config =
        insert_data_source_config(:google_drive)
        |> Map.put(:provider, :google_drive)

      assert {:ok, _page} =
               JidoConnectBridge.list_files(atom_config, %{include_permissions: true})

      assert_received {:invoke_files, atom_params, atom_opts}
      assert is_binary(atom_params[:fields] || atom_params["fields"])
      assert String.contains?(atom_params[:fields] || atom_params["fields"], "permissions(")
      assert atom_opts[:context].connection.profile == :user

      sharepoint_credential = create_credential!()
      sharepoint_grant = create_active_grant!(sharepoint_credential, 456, "user")
      Process.put(:stub_runtime_credential, sharepoint_credential)
      Process.put(:stub_runtime_grant, sharepoint_grant)

      sharepoint_config = insert_data_source_config(:sharepoint)

      assert {:ok, _page} =
               JidoConnectBridge.list_files(sharepoint_config, %{
                 include_permissions: true,
                 fields: "id,name"
               })

      assert_received {:invoke_files, sharepoint_params, _sharepoint_opts}
      assert sharepoint_params[:fields] == "id,name"
      assert sharepoint_params["fields"] in [nil, "id,name"]
    end
  end
end

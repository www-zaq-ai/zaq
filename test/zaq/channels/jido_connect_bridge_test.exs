defmodule Zaq.Channels.JidoConnectBridgeTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.{ChannelConfig, JidoConnectBridge}
  alias Zaq.Engine.Connect
  alias Zaq.Repo

  defmodule StubIntegration do
  end

  defmodule StubPermission do
    defstruct [:permission_id, :display_name, :email_address, :role, :type]
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

    def invoke(_integration, "stub.permissions.list", %{file_id: file_id}, _opts) do
      send(self(), {:invoke_permissions, file_id})

      {:ok,
       %{
         permissions: [
           %{"id" => "u1", "type" => "user", "emailAddress" => "a@example.com"},
           %{"id" => "u2", "type" => "group", "emailAddress" => "team@example.com"}
         ]
       }}
    end
  end

  defmodule StubJidoConnectStructPermissions do
    def actions(_integration) do
      StubJidoConnect.actions(nil)
    end

    def invoke(_integration, "stub.files.list", params, opts) do
      send(self(), {:invoke_files, params, opts})

      {:ok,
       %{
         files: [
           %{
             "id" => "f3",
             "name" => "Folder With Struct Permission",
             "mimeType" => "application/vnd.google-apps.folder",
             "parents" => [],
             "permissions" => [
               %StubPermission{
                 permission_id: "sp1",
                 type: "user",
                 role: "owner",
                 display_name: "Struct Owner",
                 email_address: "struct-owner@example.com"
               }
             ]
           }
         ]
       }}
    end

    def invoke(_integration, "stub.permissions.list", %{file_id: file_id}, _opts) do
      send(self(), {:invoke_permissions, file_id})

      {:ok,
       %{
         permissions: [
           %{"id" => "u1", "type" => "user", "emailAddress" => "a@example.com"}
         ]
       }}
    end
  end

  defmodule StubJidoConnectMissingPermissions do
    def actions(_integration) do
      {:ok,
       [
         %{
           id: "stub.files.list",
           resource: :file,
           verb: :list,
           auth_profile: :user,
           auth_profiles: [:user]
         }
       ]}
    end

    def invoke(_integration, "stub.files.list", _params, _opts) do
      {:ok,
       %{
         files: [
           %{
             "id" => "f1",
             "name" => "Root Folder",
             "mimeType" => "application/vnd.google-apps.folder",
             "parents" => []
           }
         ]
       }}
    end
  end

  defmodule StubJidoConnectErrorFiles do
    def actions(_integration) do
      {:ok,
       [
         %{id: "stub.files.list", resource: :file, verb: :list, auth_profiles: [:user]},
         %{
           id: "stub.permissions.list",
           resource: :permission,
           verb: :list,
           auth_profiles: [:user]
         }
       ]}
    end

    def invoke(_integration, "stub.files.list", _params, _opts), do: {:error, :boom}

    def invoke(_integration, "stub.permissions.list", _params, _opts),
      do: {:ok, %{permissions: []}}
  end

  defmodule StubJidoConnectUnsupportedPermissions do
    def actions(_integration) do
      {:ok,
       [
         %{id: "stub.files.list", resource: :file, verb: :list, auth_profiles: [:user]},
         %{
           id: "stub.permissions.list",
           resource: :permission,
           verb: :list,
           auth_profiles: [:user]
         }
       ]}
    end

    def invoke(_integration, "stub.files.list", _params, _opts) do
      {:ok,
       %{
         files: [
           %{
             "id" => "f1",
             "name" => "Doc",
             "mimeType" => "application/pdf",
             "parents" => ["root"]
           }
         ]
       }}
    end

    def invoke(_integration, "stub.permissions.list", _params, _opts), do: {:error, :unsupported}
  end

  setup do
    original_channels = Application.get_env(:zaq, :channels)
    original_jido_connect = Application.get_env(:zaq, :jido_connect_bridge_jido_connect_module)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: JidoConnectBridge, integration: StubIntegration}
    })

    Application.put_env(:zaq, :jido_connect_bridge_jido_connect_module, StubJidoConnect)

    on_exit(fn ->
      if original_channels do
        Application.put_env(:zaq, :channels, original_channels)
      else
        Application.delete_env(:zaq, :channels)
      end

      if original_jido_connect do
        Application.put_env(:zaq, :jido_connect_bridge_jido_connect_module, original_jido_connect)
      else
        Application.delete_env(:zaq, :jido_connect_bridge_jido_connect_module)
      end
    end)

    :ok
  end

  defp insert_data_source_config(provider, attrs \\ %{}) do
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

  defp create_credential! do
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

  defp create_active_grant!(credential, resource_id) do
    {:ok, grant} =
      Connect.issue_grant(%{
        credential_id: credential.id,
        auth_kind: "oauth2",
        resource_type: "data_source",
        resource_id: resource_id,
        owner_type: "org",
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

  test "invokes list_files intent using jido_connect runtime" do
    config = insert_data_source_config(:google_drive)
    credential = create_credential!()
    grant = create_active_grant!(credential, config.id)

    assert {:ok, %Zaq.Contracts.RecordPage{records: [%Zaq.Contracts.Record{id: "f1"} | _]}} =
             JidoConnectBridge.list_resources(config, %{})

    assert_received {:invoke_files, _params, opts}

    assert opts[:context].connection.id == "grant:#{grant.id}"
    assert opts[:credential_lease].connection_id == "grant:#{grant.id}"
  end

  test "list_files opportunistically maps embedded permissions on item records" do
    config = insert_data_source_config(:google_drive)
    credential = create_credential!()
    _grant = create_active_grant!(credential, config.id)

    assert {:ok, %Zaq.Contracts.RecordPage{records: records}} =
             JidoConnectBridge.list_files(config, %{})

    item = Enum.find(records, &(&1.id == "f2"))
    assert is_list(item.permissions)
    assert [%Zaq.Contracts.Record{id: "ep1", kind: :permission}] = item.permissions
  end

  test "list_files adds google drive permission fields when include_permissions is true" do
    config = insert_data_source_config(:google_drive)
    credential = create_credential!()
    _grant = create_active_grant!(credential, config.id)

    assert {:ok, _} = JidoConnectBridge.list_files(config, %{include_permissions: true})

    assert_received {:invoke_files, params, _opts}
    fields = Map.get(params, :fields) || Map.get(params, "fields")
    assert is_binary(fields)
    assert String.contains?(fields, "permissions(")
  end

  test "list_files maps embedded struct permissions with permission_id" do
    config = insert_data_source_config(:google_drive)
    credential = create_credential!()
    _grant = create_active_grant!(credential, config.id)

    Application.put_env(
      :zaq,
      :jido_connect_bridge_jido_connect_module,
      StubJidoConnectStructPermissions
    )

    assert {:ok, %Zaq.Contracts.RecordPage{records: [record]}} =
             JidoConnectBridge.list_files(config, %{})

    assert [%Zaq.Contracts.Record{id: "sp1", kind: :permission, name: "Struct Owner"}] =
             record.permissions
  end

  test "returns error when active grant is missing" do
    config = insert_data_source_config(:google_drive)

    assert {:error, :missing_active_grant} = JidoConnectBridge.list_resources(config, %{})
  end

  test "unsupported callbacks return unsupported errors" do
    config = insert_data_source_config(:google_drive)

    assert {:error, :unsupported} = JidoConnectBridge.auth_handshake(config, %{})
    assert {:error, :unsupported} = JidoConnectBridge.download_resource(config, %{}, %{})
    assert {:error, :unsupported} = JidoConnectBridge.setup_listener(config, %{})
    assert {:error, :unsupported} = JidoConnectBridge.teardown_listener(config, %{})
    assert {:error, :unsupported} = JidoConnectBridge.to_internal(%{}, config)
  end

  test "channel_stats composes files + permissions and supports partial fields" do
    config = insert_data_source_config(:google_drive)
    credential = create_credential!()
    _grant = create_active_grant!(credential, config.id)

    assert {:ok, stats} = JidoConnectBridge.channel_stats(config, %{})
    assert stats.files_count == 1
    assert stats.folders_count == 1
    assert stats.principals_count == 2
    assert stats.root_folders == ["Root Folder"]

    Application.put_env(
      :zaq,
      :jido_connect_bridge_jido_connect_module,
      StubJidoConnectMissingPermissions
    )

    assert {:ok, partial} = JidoConnectBridge.channel_stats(config, %{})
    assert partial.files_count == 0
    assert partial.folders_count == 1
    assert partial.principals_count == nil
  end

  test "channel_stats tolerates list_files failures" do
    config = insert_data_source_config(:google_drive)
    credential = create_credential!()
    _grant = create_active_grant!(credential, config.id)

    Application.put_env(:zaq, :jido_connect_bridge_jido_connect_module, StubJidoConnectErrorFiles)

    assert {:ok, stats} = JidoConnectBridge.channel_stats(config, %{})
    assert stats.files_count == nil
    assert stats.folders_count == nil
    assert stats.principals_count == 0
    assert stats._error.code == :provider_error
  end

  test "channel_stats returns unsupported capability details when permissions unsupported" do
    config = insert_data_source_config(:google_drive)
    credential = create_credential!()
    _grant = create_active_grant!(credential, config.id)

    Application.put_env(
      :zaq,
      :jido_connect_bridge_jido_connect_module,
      StubJidoConnectUnsupportedPermissions
    )

    assert {:ok, stats} = JidoConnectBridge.channel_stats(config, %{})
    assert stats.files_count == 1
    assert stats.principals_count == nil
    assert stats._error.code == :provider_error
  end

  test "capability snapshot marks unsupported capabilities when actions missing" do
    config = insert_data_source_config(:google_drive)

    Application.put_env(
      :zaq,
      :jido_connect_bridge_jido_connect_module,
      StubJidoConnectMissingPermissions
    )

    assert {:ok, snapshot} = JidoConnectBridge.capability_snapshot(config)
    assert snapshot.resolved[:list_items] == "stub.files.list"
    assert :list_principals in snapshot.unsupported
  end
end

defmodule Zaq.Channels.JidoConnectBridgeTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.{ChannelConfig, JidoConnectBridge}
  alias Zaq.Engine.Connect
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
           auth_profiles: [:user]
         },
         %{
           id: "stub.permissions.list",
           resource: :permission,
           verb: :list,
           auth_profile: :user,
           auth_profiles: [:user]
         }
       ]}
    end

    def invoke(_integration, "stub.files.list", _params, opts) do
      send(self(), {:invoke_files, opts})

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
             "parents" => ["root"]
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

    assert_received {:invoke_files, opts}

    assert opts[:context].connection.id == "grant:#{grant.id}"
    assert opts[:credential_lease].connection_id == "grant:#{grant.id}"
  end

  test "returns error when active grant is missing" do
    config = insert_data_source_config(:google_drive)

    assert {:error, :missing_active_grant} = JidoConnectBridge.list_resources(config, %{})
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
end

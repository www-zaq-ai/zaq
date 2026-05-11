defmodule Zaq.Channels.JidoConnectBridgeTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.{ChannelConfig, JidoConnectBridge}
  alias Zaq.Engine.Connect
  alias Zaq.Repo

  defmodule StubAdapter do
    def auth_handshake(runtime, params) do
      send(self(), {:auth_handshake, runtime, params})
      {:ok, %{status: :ok}}
    end

    def list_resources(runtime, params) do
      send(self(), {:list_resources, runtime, params})
      {:ok, [%{"id" => "doc-1"}]}
    end

    def download_resource(runtime, resource, params) do
      send(self(), {:download_resource, runtime, resource, params})
      {:ok, %{resource: resource, params: params}}
    end

    def setup_listener(runtime, params) do
      send(self(), {:setup_listener, runtime, params})
      {:ok, %{listener_id: "listener-1"}}
    end

    def teardown_listener(runtime, params) do
      send(self(), {:teardown_listener, runtime, params})
      :ok
    end
  end

  defmodule StubAdapterNoCallbacks do
  end

  setup do
    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: JidoConnectBridge, adapter: StubAdapter}
    })

    on_exit(fn ->
      if original_channels do
        Application.put_env(:zaq, :channels, original_channels)
      else
        Application.delete_env(:zaq, :channels)
      end
    end)

    :ok
  end

  defp insert_data_source_config(provider, attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    base = %{
      name: "cfg-#{provider}-#{unique}",
      provider: to_string(provider),
      kind: "ingestion",
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
        auth_kind: "api_key",
        request_format: "bearer",
        user_level: false,
        metadata: %{},
        api_key: "secret-api-key"
      })

    credential
  end

  defp create_active_grant!(credential, resource_id) do
    {:ok, grant} =
      Connect.issue_grant(%{
        credential_id: credential.id,
        auth_kind: "api_key",
        resource_type: "data_source",
        resource_id: resource_id,
        owner_type: "org",
        owner_id: nil,
        request_format: "bearer",
        metadata: %{},
        status: "active",
        api_key: "grant-key"
      })

    grant
  end

  test "delegates datasource operations with connect runtime context" do
    config = insert_data_source_config(:google_drive)
    credential = create_credential!()
    _grant = create_active_grant!(credential, config.id)

    assert {:ok, %{status: :ok}} = JidoConnectBridge.auth_handshake(config, %{"scope" => "read"})
    assert_received {:auth_handshake, runtime, %{"scope" => "read"}}
    assert runtime.connection.id == "grant:#{runtime.grant.id}"
    assert runtime.credential.id == credential.id

    assert {:ok, [%{"id" => "doc-1"}]} = JidoConnectBridge.list_resources(config, %{})
    assert_received {:list_resources, _runtime, %{}}

    assert {:ok, _} =
             JidoConnectBridge.download_resource(config, %{"id" => "doc-1"}, %{"target" => "tmp"})

    assert_received {:download_resource, _runtime, %{"id" => "doc-1"}, %{"target" => "tmp"}}

    assert {:ok, %{listener_id: "listener-1"}} = JidoConnectBridge.setup_listener(config, %{})
    assert_received {:setup_listener, _runtime, %{}}

    assert :ok = JidoConnectBridge.teardown_listener(config, %{"listener_id" => "listener-1"})
    assert_received {:teardown_listener, _runtime, %{"listener_id" => "listener-1"}}
  end

  test "returns error when active grant is missing" do
    config = insert_data_source_config(:google_drive)

    assert {:error, :missing_active_grant} = JidoConnectBridge.list_resources(config, %{})
  end

  test "returns unsupported when adapter callback is missing" do
    config = insert_data_source_config(:google_drive)
    credential = create_credential!()
    _grant = create_active_grant!(credential, config.id)

    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: JidoConnectBridge, adapter: StubAdapterNoCallbacks}
    })

    on_exit(fn ->
      Application.put_env(:zaq, :channels, original_channels)
    end)

    assert {:error, :unsupported} = JidoConnectBridge.list_resources(config, %{})
  end
end

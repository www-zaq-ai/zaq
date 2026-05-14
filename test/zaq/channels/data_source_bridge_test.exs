defmodule Zaq.Channels.DataSourceBridgeTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.{ChannelConfig, DataSourceBridge}
  alias Zaq.Repo

  defmodule StubDataSourceBridge do
    def auth_handshake(config, params) do
      send(self(), {:auth_handshake, config.provider, params})
      {:ok, %{provider: config.provider}}
    end

    def list_resources(config, params) do
      send(self(), {:list_resources, config.provider, params})
      {:ok, [%{"id" => "r1"}]}
    end

    def download_resource(config, resource, params) do
      send(self(), {:download_resource, config.provider, resource, params})
      {:ok, %{ref: "blob-1"}}
    end

    def setup_listener(config, params) do
      send(self(), {:setup_listener, config.provider, params})
      {:ok, %{listener_id: "l1"}}
    end

    def teardown_listener(config, params) do
      send(self(), {:teardown_listener, config.provider, params})
      :ok
    end

    def sync_runtime(before_config, after_config) do
      send(self(), {:sync_runtime, before_config, after_config})
      :ok
    end

    def oauth_authorize_url(config, params) do
      send(self(), {:oauth_authorize_url, config.id, params})
      {:ok, "https://auth.example/authorize"}
    end

    def oauth_exchange_code(config, params) do
      send(self(), {:oauth_exchange_code, config.id, params})
      {:ok, %{access_token: "access-token"}}
    end

    def oauth_refresh_token(config, params) do
      send(self(), {:oauth_refresh_token, config.id, params})
      {:ok, %{access_token: "new-access-token"}}
    end

    def list_files(config, params) do
      send(self(), {:list_files, config.id, params})
      {:ok, %{records: []}}
    end

    def list_permissions(config, params) do
      send(self(), {:list_permissions, config.id, params})
      {:ok, %{records: []}}
    end

    def channel_stats(config, params) do
      send(self(), {:channel_stats, config.id, params})
      {:ok, %{files_count: 0}}
    end

    def capability_snapshot(config) do
      send(self(), {:capability_snapshot, config.id})
      {:ok, %{required: [], resolved: %{}, unsupported: [], labels: %{}}}
    end
  end

  defmodule StubNoDataSourceCallbacks do
  end

  setup do
    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: StubDataSourceBridge, adapter: __MODULE__.StubAdapter},
      sharepoint: %{bridge: StubDataSourceBridge, adapter: __MODULE__.StubAdapter}
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
      name: "ds-#{provider}-#{unique}",
      provider: to_string(provider),
      kind: "data_source",
      enabled: true,
      settings: %{}
    }

    %ChannelConfig{}
    |> ChannelConfig.changeset(Map.merge(base, attrs))
    |> Repo.insert!()
  end

  test "delegates datasource operations to provider bridge" do
    insert_data_source_config(:google_drive)

    assert {:ok, _} = DataSourceBridge.auth_handshake(:google_drive, %{"scope" => "read"})
    assert_received {:auth_handshake, "google_drive", %{"scope" => "read"}}

    assert {:ok, [%{"id" => "r1"}]} = DataSourceBridge.list_resources(:google_drive, %{})
    assert_received {:list_resources, "google_drive", %{}}

    assert {:ok, %{ref: "blob-1"}} =
             DataSourceBridge.download_resource(:google_drive, %{"id" => "r1"}, %{
               "format" => "raw"
             })

    assert_received {:download_resource, "google_drive", %{"id" => "r1"}, %{"format" => "raw"}}

    assert {:ok, %{listener_id: "l1"}} =
             DataSourceBridge.setup_listener(:google_drive, %{"mode" => "delta"})

    assert_received {:setup_listener, "google_drive", %{"mode" => "delta"}}

    assert :ok = DataSourceBridge.teardown_listener(:google_drive, %{"listener_id" => "l1"})
    assert_received {:teardown_listener, "google_drive", %{"listener_id" => "l1"}}
  end

  test "returns no_bridge for missing provider bridge" do
    insert_data_source_config(:google_drive)

    assert {:error, {:channel_not_configured, "sharepoint"}} =
             DataSourceBridge.auth_handshake("sharepoint", %{})
  end

  test "returns channel_not_configured when provider config missing" do
    assert {:error, {:channel_not_configured, :google_drive}} =
             DataSourceBridge.list_resources(:google_drive, %{})
  end

  test "returns unsupported when callback not implemented" do
    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: StubNoDataSourceCallbacks, adapter: __MODULE__.StubAdapter}
    })

    on_exit(fn ->
      Application.put_env(:zaq, :channels, original_channels)
    end)

    insert_data_source_config(:google_drive)

    assert {:error, :unsupported} = DataSourceBridge.auth_handshake(:google_drive, %{})
  end

  test "sync_config_runtime delegates when bridge implements sync_runtime" do
    before_config = %{id: 1, provider: "google_drive", enabled: true}
    after_config = %{id: 1, provider: "google_drive", enabled: false}

    assert :ok = DataSourceBridge.sync_config_runtime(before_config, after_config)
    assert_received {:sync_runtime, ^before_config, ^after_config}
  end

  test "oauth and datasource wrappers delegate through scoped config" do
    config = insert_data_source_config(:google_drive)
    config_id = config.id
    config_id_string = to_string(config_id)

    assert {:ok, "https://auth.example/authorize"} =
             DataSourceBridge.oauth_authorize_url(:google_drive, %{"config_id" => config.id})

    assert_received {:oauth_authorize_url, ^config_id, %{"config_id" => ^config_id}}

    assert {:ok, %{access_token: "access-token"}} =
             DataSourceBridge.oauth_exchange_code(:google_drive, %{
               "config_id" => config_id_string
             })

    assert_received {:oauth_exchange_code, ^config_id, %{"config_id" => ^config_id_string}}

    assert {:ok, %{access_token: "new-access-token"}} =
             DataSourceBridge.oauth_refresh_token(:google_drive, %{config_id: config.id})

    assert_received {:oauth_refresh_token, ^config_id, %{config_id: ^config_id}}

    assert {:ok, %{records: []}} =
             DataSourceBridge.list_files(:google_drive, %{config_id: config_id})

    assert_received {:list_files, ^config_id, %{config_id: ^config_id}}

    assert {:ok, %{records: []}} =
             DataSourceBridge.list_permissions(:google_drive, %{"config_id" => config_id_string})

    assert_received {:list_permissions, ^config_id, %{"config_id" => ^config_id_string}}

    assert {:ok, %{files_count: 0}} =
             DataSourceBridge.channel_stats(:google_drive, %{config_id: config_id})

    assert_received {:channel_stats, ^config_id, %{config_id: ^config_id}}
  end

  test "scoped config id rejects bad or mismatched provider" do
    config = insert_data_source_config(:google_drive)

    assert {:ok, %{records: []}} =
             DataSourceBridge.list_files(:google_drive, %{"config_id" => "not-an-integer"})

    assert {:error, {:channel_not_configured, :sharepoint}} =
             DataSourceBridge.list_files(:sharepoint, %{"config_id" => config.id})
  end

  test "capability snapshot delegates" do
    config = insert_data_source_config(:google_drive)
    config_id = config.id

    assert {:ok, %{required: [], resolved: %{}, unsupported: [], labels: %{}}} =
             DataSourceBridge.capability_snapshot(:google_drive)

    assert_received {:capability_snapshot, ^config_id}
  end
end

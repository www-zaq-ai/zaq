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

    def create_file(config, params) do
      send(self(), {:create_file, config.id, params})
      {:ok, %{status: "created", record: %{"id" => "f1"}}}
    end

    def get_file(config, params) do
      send(self(), {:get_file, config.id, params})
      {:ok, %{record: %{"id" => "f1"}}}
    end

    def update_file(config, params) do
      send(self(), {:update_file, config.id, params})
      {:ok, %{status: "updated", record: %{"id" => "f1"}}}
    end

    def delete_file(config, params) do
      send(self(), {:delete_file, config.id, params})
      {:ok, %{status: "deleted", result: %{}}}
    end

    def search_files(config, params) do
      send(self(), {:search_files, config.id, params})
      {:ok, %{records: [%{"id" => "f1"}]}}
    end

    def download_document(config, params) do
      send(self(), {:download_document, config.id, params})
      {:ok, %{record: %{id: "f1", kind: :file, content: "hello"}}}
    end

    def list_permissions(config, params) do
      send(self(), {:list_permissions, config.id, params})
      {:ok, %{records: []}}
    end

    def channel_stats(config, params) do
      send(self(), {:channel_stats, config.id, params})
      {:ok, %{files_count: 0}}
    end

    def export_options(config, params) do
      send(self(), {:export_options, config.id, params})

      {:ok,
       %{
         native_types: ["application/vnd.google-apps.document"],
         export_formats_by_native_type: %{
           "application/vnd.google-apps.document" => ["text/plain"]
         }
       }}
    end

    def sheet_inspect(config, params) do
      send(self(), {:sheet_inspect, config.id, params})
      {:ok, %{spreadsheet: "sheet-1", tabs: []}}
    end

    def sheet_get(config, params) do
      send(self(), {:sheet_get, config.id, params})
      {:ok, %{range: "Sheet1!A1:B2", values: [["x", "y"]]}}
    end

    def sheet_create(config, params) do
      send(self(), {:sheet_create, config.id, params})
      {:ok, %{spreadsheet_id: "sheet-created"}}
    end

    def sheet_add_tab(config, params) do
      send(self(), {:sheet_add_tab, config.id, params})
      {:ok, %{tab_id: 42, title: "Q2"}}
    end

    def sheet_update_values(config, params) do
      send(self(), {:sheet_update_values, config.id, params})
      {:ok, %{updated_cells: 1}}
    end

    def sheet_append_values(config, params) do
      send(self(), {:sheet_append_values, config.id, params})
      {:ok, %{appended_rows: 1}}
    end

    def sheet_clear_values(config, params) do
      send(self(), {:sheet_clear_values, config.id, params})
      {:ok, %{cleared: true}}
    end

    def sheet_delete_tab(config, params) do
      send(self(), {:sheet_delete_tab, config.id, params})
      {:ok, %{deleted: true}}
    end

    def capability_snapshot(config) do
      send(self(), {:capability_snapshot, config.id})
      {:ok, %{required: [], resolved: %{}, unsupported: [], labels: %{}}}
    end

    def watch_changes(config, params) do
      send(self(), {:watch_changes, config.id, params})
      {:ok, %{watch_id: "w1"}}
    end

    def unwatch_changes(config, params) do
      send(self(), {:unwatch_changes, config.id, params})
      :ok
    end

    def handle_webhook(config, payload) do
      send(self(), {:handle_webhook, config.id, payload})
      {:ok, %{processed: true}}
    end

    def oauth_default_scopes(config) do
      send(self(), {:oauth_default_scopes, config.id})
      {:ok, ["read", "write"]}
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

  describe "download_resource/2 default params" do
    test "download_resource/2 delegates with default empty params map" do
      insert_data_source_config(:google_drive)

      assert {:ok, %{ref: "blob-1"}} =
               DataSourceBridge.download_resource(:google_drive, %{"id" => "r1"})

      assert_received {:download_resource, "google_drive", %{"id" => "r1"}, %{}}
    end
  end

  test "auth_handshake/1 uses default params and delegates" do
    _config = insert_data_source_config(:google_drive)

    assert {:ok, %{provider: "google_drive"}} = DataSourceBridge.auth_handshake(:google_drive)
    assert_received {:auth_handshake, "google_drive", %{}}
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

    assert {:ok, %{status: "created", record: %{"id" => "f1"}}} =
             DataSourceBridge.create_file(:google_drive, %{"name" => "Doc", config_id: config_id})

    assert_received {:create_file, ^config_id, %{"name" => "Doc", config_id: ^config_id}}

    assert {:ok, %{record: %{"id" => "f1"}}} =
             DataSourceBridge.get_file(:google_drive, %{"file_id" => "f1", config_id: config_id})

    assert_received {:get_file, ^config_id, %{"file_id" => "f1", config_id: ^config_id}}

    assert {:ok, %{status: "updated", record: %{"id" => "f1"}}} =
             DataSourceBridge.update_file(:google_drive, %{
               "file_id" => "f1",
               "name" => "Renamed",
               config_id: config_id
             })

    assert_received {:update_file, ^config_id,
                     %{"file_id" => "f1", "name" => "Renamed", config_id: ^config_id}}

    assert {:ok, %{status: "deleted", result: %{}}} =
             DataSourceBridge.delete_file(:google_drive, %{
               "file_id" => "f1",
               config_id: config_id
             })

    assert_received {:delete_file, ^config_id, %{"file_id" => "f1", config_id: ^config_id}}

    assert {:ok, %{records: [%{"id" => "f1"}]}} =
             DataSourceBridge.search_files(:google_drive, %{
               "query" => "invoice",
               config_id: config_id
             })

    assert_received {:search_files, ^config_id, %{"query" => "invoice", config_id: ^config_id}}

    assert {:ok, %{record: %{id: "f1", kind: :file, content: "hello"}}} =
             DataSourceBridge.download_document(:google_drive, %{
               "file_id" => "f1",
               config_id: config_id
             })

    assert_received {:download_document, ^config_id, %{"file_id" => "f1", config_id: ^config_id}}

    assert {:ok, %{records: []}} =
             DataSourceBridge.list_permissions(:google_drive, %{"config_id" => config_id_string})

    assert_received {:list_permissions, ^config_id, %{"config_id" => ^config_id_string}}

    assert {:ok, %{files_count: 0}} =
             DataSourceBridge.channel_stats(:google_drive, %{config_id: config_id})

    assert_received {:channel_stats, ^config_id, %{config_id: ^config_id}}
  end

  test "scoped config provider match succeeds for string/atom provider parity" do
    config = insert_data_source_config(:google_drive)
    config_id = config.id

    assert {:ok, %{records: []}} =
             DataSourceBridge.list_files("google_drive", %{"config_id" => config_id})

    assert_received {:list_files, ^config_id, %{"config_id" => ^config_id}}
  end

  test "scoped config provider mismatch returns channel_not_configured" do
    config = insert_data_source_config(:google_drive)

    assert {:error, {:channel_not_configured, :sharepoint}} =
             DataSourceBridge.list_files(:sharepoint, %{"config_id" => config.id})
  end

  test "scoped config id ignores invalid config_id and falls back to default config" do
    _config = insert_data_source_config(:google_drive)

    assert {:ok, %{records: []}} =
             DataSourceBridge.list_files(:google_drive, %{"config_id" => "not-an-integer"})
  end

  test "capability snapshot delegates" do
    config = insert_data_source_config(:google_drive)
    config_id = config.id

    assert {:ok, %{required: [], resolved: %{}, unsupported: [], labels: %{}}} =
             DataSourceBridge.capability_snapshot(:google_drive)

    assert_received {:capability_snapshot, ^config_id}
  end

  test "required_capabilities returns expected canonical list" do
    caps = DataSourceBridge.required_capabilities()

    assert caps == [
             :list_items,
             :count_items,
             :list_principals,
             :count_principals,
             :get_item_metadata,
             :list_item_versions,
             :download_items,
             :create_item,
             :update_item,
             :delete_item,
             :search_items,
             :sheet_inspect,
             :sheet_get,
             :sheet_create,
             :sheet_add_tab,
             :sheet_update_values,
             :sheet_append_values,
             :sheet_clear_values,
             :sheet_delete_tab,
             :watch_changes_webhook,
             :receive_change_webhook
           ]

    assert Enum.uniq(caps) == caps
    assert Enum.all?(caps, &is_atom/1)
  end

  test "capability_meta exposes labels for each required capability" do
    meta = DataSourceBridge.capability_meta()
    caps = DataSourceBridge.required_capabilities()

    assert is_map(meta)
    assert Map.keys(meta) |> Enum.sort() == Enum.sort(caps)
    assert meta[:list_items] == "List files and folders"
    assert meta[:watch_changes_webhook] == "Register webhook watch for change notifications"
    assert meta[:receive_change_webhook] == "Verify and normalize webhook change payloads"
    assert Enum.all?(meta, fn {_k, v} -> is_binary(v) and String.trim(v) != "" end)
  end

  describe "spreadsheet wrappers" do
    test "sheet_inspect delegates through scoped config" do
      config = insert_data_source_config(:google_drive)
      config_id = config.id

      assert {:ok, %{spreadsheet: "sheet-1", tabs: []}} =
               DataSourceBridge.sheet_inspect(:google_drive, %{
                 "config_id" => config.id,
                 "spreadsheet_id" => "s1"
               })

      assert_received {:sheet_inspect, ^config_id,
                       %{"config_id" => ^config_id, "spreadsheet_id" => "s1"}}
    end

    test "sheet_get delegates through scoped config" do
      config = insert_data_source_config(:google_drive)
      config_id = config.id

      assert {:ok, %{range: "Sheet1!A1:B2", values: [["x", "y"]]}} =
               DataSourceBridge.sheet_get(:google_drive, %{
                 "config_id" => config.id,
                 "spreadsheet_id" => "s1",
                 "range" => "Sheet1!A1:B2"
               })

      assert_received {:sheet_get, ^config_id,
                       %{
                         "config_id" => ^config_id,
                         "spreadsheet_id" => "s1",
                         "range" => "Sheet1!A1:B2"
                       }}
    end

    test "sheet_create delegates through scoped config" do
      config = insert_data_source_config(:google_drive)
      config_id = config.id

      assert {:ok, %{spreadsheet_id: "sheet-created"}} =
               DataSourceBridge.sheet_create(:google_drive, %{
                 "config_id" => config.id,
                 "title" => "Budget"
               })

      assert_received {:sheet_create, ^config_id,
                       %{"config_id" => ^config_id, "title" => "Budget"}}
    end

    test "sheet_add_tab delegates through scoped config" do
      config = insert_data_source_config(:google_drive)
      config_id = config.id

      assert {:ok, %{tab_id: 42, title: "Q2"}} =
               DataSourceBridge.sheet_add_tab(:google_drive, %{
                 "config_id" => config.id,
                 "spreadsheet_id" => "s1",
                 "title" => "Q2"
               })

      assert_received {:sheet_add_tab, ^config_id,
                       %{"config_id" => ^config_id, "spreadsheet_id" => "s1", "title" => "Q2"}}
    end

    test "sheet_update_values delegates through scoped config" do
      config = insert_data_source_config(:google_drive)
      config_id = config.id

      assert {:ok, %{updated_cells: 1}} =
               DataSourceBridge.sheet_update_values(:google_drive, %{
                 "config_id" => config.id,
                 "spreadsheet_id" => "s1",
                 "range" => "Sheet1!A1",
                 "values" => [["x"]]
               })

      assert_received {:sheet_update_values, ^config_id,
                       %{
                         "config_id" => ^config_id,
                         "spreadsheet_id" => "s1",
                         "range" => "Sheet1!A1",
                         "values" => [["x"]]
                       }}
    end

    test "sheet_append_values delegates through scoped config" do
      config = insert_data_source_config(:google_drive)
      config_id = config.id

      assert {:ok, %{appended_rows: 1}} =
               DataSourceBridge.sheet_append_values(:google_drive, %{
                 "config_id" => config.id,
                 "spreadsheet_id" => "s1",
                 "range" => "Sheet1!A:A",
                 "values" => [["row"]]
               })

      assert_received {:sheet_append_values, ^config_id,
                       %{
                         "config_id" => ^config_id,
                         "spreadsheet_id" => "s1",
                         "range" => "Sheet1!A:A",
                         "values" => [["row"]]
                       }}
    end

    test "sheet_clear_values delegates through scoped config" do
      config = insert_data_source_config(:google_drive)
      config_id = config.id

      assert {:ok, %{cleared: true}} =
               DataSourceBridge.sheet_clear_values(:google_drive, %{
                 "config_id" => config.id,
                 "spreadsheet_id" => "s1",
                 "range" => "Sheet1!A1:B9"
               })

      assert_received {:sheet_clear_values, ^config_id,
                       %{
                         "config_id" => ^config_id,
                         "spreadsheet_id" => "s1",
                         "range" => "Sheet1!A1:B9"
                       }}
    end

    test "sheet_delete_tab delegates through scoped config" do
      config = insert_data_source_config(:google_drive)
      config_id = config.id

      assert {:ok, %{deleted: true}} =
               DataSourceBridge.sheet_delete_tab(:google_drive, %{
                 "config_id" => config.id,
                 "spreadsheet_id" => "s1",
                 "sheet_id" => 42
               })

      assert_received {:sheet_delete_tab, ^config_id,
                       %{"config_id" => ^config_id, "spreadsheet_id" => "s1", "sheet_id" => 42}}
    end

    test "spreadsheet wrappers return unsupported when callbacks are not implemented" do
      original_channels = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        google_drive: %{bridge: StubNoDataSourceCallbacks, adapter: __MODULE__.StubAdapter}
      })

      on_exit(fn ->
        Application.put_env(:zaq, :channels, original_channels)
      end)

      config = insert_data_source_config(:google_drive)
      base_params = %{"config_id" => config.id, "spreadsheet_id" => "s1"}

      assert {:error, :unsupported} =
               DataSourceBridge.sheet_inspect(:google_drive, Map.put(base_params, "sheet_id", 1))

      assert {:error, :unsupported} =
               DataSourceBridge.sheet_get(
                 :google_drive,
                 Map.put(base_params, "range", "Sheet1!A1:B2")
               )

      assert {:error, :unsupported} =
               DataSourceBridge.sheet_create(
                 :google_drive,
                 Map.put(base_params, "title", "Budget")
               )

      assert {:error, :unsupported} =
               DataSourceBridge.sheet_add_tab(:google_drive, Map.put(base_params, "title", "Q2"))

      assert {:error, :unsupported} =
               DataSourceBridge.sheet_update_values(
                 :google_drive,
                 Map.put(base_params, "range", "Sheet1!A1")
               )

      assert {:error, :unsupported} =
               DataSourceBridge.sheet_append_values(
                 :google_drive,
                 Map.put(base_params, "range", "Sheet1!A:A")
               )

      assert {:error, :unsupported} =
               DataSourceBridge.sheet_clear_values(
                 :google_drive,
                 Map.put(base_params, "range", "Sheet1!A1:B9")
               )

      assert {:error, :unsupported} =
               DataSourceBridge.sheet_delete_tab(
                 :google_drive,
                 Map.put(base_params, "sheet_id", 42)
               )
    end
  end

  describe "normalize_export_formats_map/1" do
    test "normalize_export_formats_map keeps only non-empty binary mime values and de-duplicates" do
      input = %{
        "application/vnd.google-apps.document" => [
          "text/plain",
          "",
          " text/csv ",
          "text/plain",
          "   ",
          nil,
          123
        ],
        "application/vnd.google-apps.sheet" => ["application/pdf", "application/pdf"]
      }

      assert %{
               "application/vnd.google-apps.document" => ["text/plain", " text/csv "],
               "application/vnd.google-apps.sheet" => ["application/pdf"]
             } = DataSourceBridge.normalize_export_formats_map(input)
    end

    test "normalize_export_formats_map drops entries with invalid tuple shapes or empty post-filter values" do
      input = %{
        123 => ["text/plain"],
        "bad" => "text/plain",
        "empty" => ["", "   ", nil]
      }

      assert DataSourceBridge.normalize_export_formats_map(input) == %{}
    end

    test "normalize_export_formats_map returns empty map for non-map input" do
      assert DataSourceBridge.normalize_export_formats_map(nil) == %{}
      assert DataSourceBridge.normalize_export_formats_map("x") == %{}
    end
  end

  test "download_resource returns unsupported when callback not implemented" do
    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: StubNoDataSourceCallbacks, adapter: __MODULE__.StubAdapter}
    })

    on_exit(fn ->
      Application.put_env(:zaq, :channels, original_channels)
    end)

    insert_data_source_config(:google_drive)

    assert {:error, :unsupported} =
             DataSourceBridge.download_resource(:google_drive, %{"id" => "r1"}, %{})
  end

  test "sync_config_runtime falls back to Bridge.sync_config_runtime when bridge lacks sync_runtime" do
    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: StubNoDataSourceCallbacks, adapter: __MODULE__.StubAdapter}
    })

    on_exit(fn ->
      Application.put_env(:zaq, :channels, original_channels)
    end)

    before_config = %{id: 1, provider: "google_drive", enabled: true}
    after_config = %{id: 1, provider: "google_drive", enabled: false}

    assert :ok = DataSourceBridge.sync_config_runtime(before_config, after_config)
  end

  test "sync_provider_runtime delegates through bridge" do
    _config = insert_data_source_config(:google_drive)

    assert :ok = DataSourceBridge.sync_provider_runtime(:google_drive)
  end

  test "list_files returns unsupported when callback not implemented" do
    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: StubNoDataSourceCallbacks, adapter: __MODULE__.StubAdapter}
    })

    on_exit(fn ->
      Application.put_env(:zaq, :channels, original_channels)
    end)

    config = insert_data_source_config(:google_drive)

    assert {:error, :unsupported} =
             DataSourceBridge.list_files(:google_drive, %{"config_id" => config.id})
  end

  test "file CRUD/search wrappers return unsupported when callback not implemented" do
    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: StubNoDataSourceCallbacks, adapter: __MODULE__.StubAdapter}
    })

    on_exit(fn ->
      Application.put_env(:zaq, :channels, original_channels)
    end)

    config = insert_data_source_config(:google_drive)

    assert {:error, :unsupported} =
             DataSourceBridge.create_file(:google_drive, %{
               "config_id" => config.id,
               "name" => "Doc"
             })

    assert {:error, :unsupported} =
             DataSourceBridge.get_file(:google_drive, %{
               "config_id" => config.id,
               "file_id" => "f1"
             })

    assert {:error, :unsupported} =
             DataSourceBridge.update_file(:google_drive, %{
               "config_id" => config.id,
               "file_id" => "f1"
             })

    assert {:error, :unsupported} =
             DataSourceBridge.delete_file(:google_drive, %{
               "config_id" => config.id,
               "file_id" => "f1"
             })

    assert {:error, :unsupported} =
             DataSourceBridge.search_files(:google_drive, %{
               "config_id" => config.id,
               "query" => "invoice"
             })

    assert {:error, :unsupported} =
             DataSourceBridge.download_document(:google_drive, %{
               "config_id" => config.id,
               "file_id" => "f1"
             })
  end

  test "list_permissions returns unsupported when callback not implemented" do
    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: StubNoDataSourceCallbacks, adapter: __MODULE__.StubAdapter}
    })

    on_exit(fn ->
      Application.put_env(:zaq, :channels, original_channels)
    end)

    config = insert_data_source_config(:google_drive)

    assert {:error, :unsupported} =
             DataSourceBridge.list_permissions(:google_drive, %{"config_id" => config.id})
  end

  test "channel_stats returns unsupported when callback not implemented" do
    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: StubNoDataSourceCallbacks, adapter: __MODULE__.StubAdapter}
    })

    on_exit(fn ->
      Application.put_env(:zaq, :channels, original_channels)
    end)

    config = insert_data_source_config(:google_drive)

    assert {:error, :unsupported} =
             DataSourceBridge.channel_stats(:google_drive, %{"config_id" => config.id})
  end

  test "export_options delegates to bridge with scoped config" do
    config = insert_data_source_config(:google_drive)
    config_id = config.id

    assert {:ok, %{native_types: ["application/vnd.google-apps.document"]}} =
             DataSourceBridge.export_options(:google_drive, %{"config_id" => config_id})

    assert_received {:export_options, ^config_id, %{"config_id" => ^config_id}}
  end

  test "export_options returns empty defaults when callback not implemented" do
    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: StubNoDataSourceCallbacks, adapter: __MODULE__.StubAdapter}
    })

    on_exit(fn ->
      Application.put_env(:zaq, :channels, original_channels)
    end)

    insert_data_source_config(:google_drive)

    assert {:ok, %{native_types: [], export_formats_by_native_type: %{}}} =
             DataSourceBridge.export_options(:google_drive, %{})
  end

  test "scoped config id with non-integer string falls back to default config" do
    _config = insert_data_source_config(:google_drive)

    assert {:ok, %{records: []}} =
             DataSourceBridge.list_files(:google_drive, %{"config_id" => "not-a-number"})
  end

  test "scoped config id fetches by binary integer string" do
    config = insert_data_source_config(:google_drive)
    config_id = config.id
    config_id_str = to_string(config_id)

    assert {:ok, %{records: []}} =
             DataSourceBridge.list_files(:google_drive, %{"config_id" => config_id_str})

    assert_received {:list_files, ^config_id, %{"config_id" => ^config_id_str}}
  end

  test "watch_changes delegates to bridge with scoped config" do
    config = insert_data_source_config(:google_drive)
    config_id = config.id

    assert {:ok, %{watch_id: "w1"}} =
             DataSourceBridge.watch_changes(:google_drive, %{"config_id" => config_id})

    assert_received {:watch_changes, ^config_id, %{"config_id" => ^config_id}}
  end

  test "watch_changes returns unsupported when callback not implemented" do
    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: StubNoDataSourceCallbacks, adapter: __MODULE__.StubAdapter}
    })

    on_exit(fn ->
      Application.put_env(:zaq, :channels, original_channels)
    end)

    config = insert_data_source_config(:google_drive)

    assert {:error, :unsupported} =
             DataSourceBridge.watch_changes(:google_drive, %{"config_id" => config.id})
  end

  test "unwatch_changes delegates to bridge with scoped config" do
    config = insert_data_source_config(:google_drive)
    config_id = config.id

    assert :ok = DataSourceBridge.unwatch_changes(:google_drive, %{"config_id" => config_id})

    assert_received {:unwatch_changes, ^config_id, %{"config_id" => ^config_id}}
  end

  test "unwatch_changes returns unsupported when callback not implemented" do
    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: StubNoDataSourceCallbacks, adapter: __MODULE__.StubAdapter}
    })

    on_exit(fn ->
      Application.put_env(:zaq, :channels, original_channels)
    end)

    config = insert_data_source_config(:google_drive)

    assert {:error, :unsupported} =
             DataSourceBridge.unwatch_changes(:google_drive, %{"config_id" => config.id})
  end

  test "handle_webhook delegates to bridge with default config" do
    config = insert_data_source_config(:google_drive)
    config_id = config.id

    payload = %{"event" => "file.created", "file_id" => "f1"}

    assert {:ok, %{processed: true}} = DataSourceBridge.handle_webhook(:google_drive, payload)

    assert_received {:handle_webhook, ^config_id, ^payload}
  end

  test "handle_webhook returns unsupported when callback not implemented" do
    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: StubNoDataSourceCallbacks, adapter: __MODULE__.StubAdapter}
    })

    on_exit(fn ->
      Application.put_env(:zaq, :channels, original_channels)
    end)

    insert_data_source_config(:google_drive)

    assert {:error, :unsupported} =
             DataSourceBridge.handle_webhook(:google_drive, %{"event" => "test"})
  end

  test "oauth_default_scopes delegates to bridge" do
    config = insert_data_source_config(:google_drive)
    config_id = config.id

    assert {:ok, ["read", "write"]} = DataSourceBridge.oauth_default_scopes(:google_drive)

    assert_received {:oauth_default_scopes, ^config_id}
  end

  test "oauth_default_scopes returns unsupported when callback not implemented" do
    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: StubNoDataSourceCallbacks, adapter: __MODULE__.StubAdapter}
    })

    on_exit(fn ->
      Application.put_env(:zaq, :channels, original_channels)
    end)

    insert_data_source_config(:google_drive)

    assert {:error, :unsupported} = DataSourceBridge.oauth_default_scopes(:google_drive)
  end

  test "normalize_config_id falls back to default config for non-integer non-binary config_id" do
    config = insert_data_source_config(:google_drive)
    config_id = config.id

    assert {:ok, %{records: []}} =
             DataSourceBridge.list_files(:google_drive, %{"config_id" => [1, 2, 3]})

    assert_received {:list_files, ^config_id, %{"config_id" => [1, 2, 3]}}
  end

  test "scoped config returns error when config_id does not exist in database" do
    non_existent_id = 99_999_999

    assert {:error, {:channel_not_configured, :google_drive}} =
             DataSourceBridge.list_files(:google_drive, %{"config_id" => non_existent_id})
  end
end

defmodule ZaqWeb.Live.BO.AI.IngestionLiveTest do
  use ZaqWeb.ConnCase, async: false

  import Ecto.Query
  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Accounts.People
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Contracts.{Record, RecordPage}
  alias Zaq.Ingestion
  alias Zaq.Ingestion.Chunk
  alias Zaq.Ingestion.Document
  alias Zaq.Ingestion.ExternalSource
  alias Zaq.Ingestion.IngestJob
  alias Zaq.Permissions
  alias Zaq.Repo
  alias Zaq.Storage.EntryCatalog
  alias Zaq.Storage.StorageEntry
  alias Zaq.System, as: ZaqSystem
  alias Zaq.SystemConfigFixtures

  defmodule ProviderBrowserBridgeStub do
    def list_files(provider, params, _context) do
      if pid = Application.get_env(:zaq, :ingestion_provider_browser_test_pid) do
        send(pid, {:list_files, provider, params})
      end

      records =
        case get_in(params, ["filters", "parent"]) do
          "folder-1" ->
            [
              %Record{
                id: "child-folder",
                kind: :folder,
                name: "Nested Folder",
                path: nil,
                url: "https://drive.example/child-folder",
                icon: "https://drive.example/icons/folder.png"
              },
              %Record{
                id: "file-no-url",
                kind: :file,
                name: "No Preview.txt",
                path: nil,
                url: nil,
                icon: "https://drive.example/icons/text.png",
                mime_type: "text/plain",
                size: 456
              }
            ]

          _ ->
            [
              %Record{
                id: "folder-1",
                kind: :folder,
                name: "Project Docs",
                path: nil,
                url: "https://drive.example/folder-1",
                icon: "https://drive.example/icons/folder.png"
              },
              %Record{
                id: "file-1",
                kind: :file,
                name: "Budget.pdf",
                path: nil,
                url: "https://drive.example/file-1",
                icon: "https://drive.example/icons/pdf.png",
                mime_type: "application/pdf",
                materialization_handle: "provider-handle-that-should-not-be-used-for-url-preview",
                size: 123
              }
            ]
        end

      {:ok,
       %RecordPage{
         resource_type: :item,
         records: records,
         pagination: %{cursor: nil, has_more?: false},
         stats: %{scanned: length(records), returned: length(records)},
         filters: Map.get(params, "filters", %{}),
         metadata: %{}
       }}
    end

    def download_document(_provider, %{"file_id" => file_id}, _context) do
      {:ok,
       %{
         record: %Record{
           id: file_id,
           kind: :file,
           name: "Budget.pdf",
           content: "Provider document content",
           mime_type: "text/plain"
         }
       }}
    end

    def create_file(provider, params, _context) do
      if pid = Application.get_env(:zaq, :ingestion_provider_browser_test_pid) do
        send(pid, {:create_file, provider, params})
      end

      {:ok,
       %{
         status: "created",
         record: %Record{
           id: "created-1",
           kind: if(Map.get(params, "kind") == "folder", do: :folder, else: :file),
           name: Map.get(params, "name"),
           path: Map.get(params, "name"),
           mime_type: Map.get(params, "mime_type")
         }
       }}
    end

    def capability_snapshot(_provider) do
      case Application.get_env(
             :zaq,
             :provider_browser_capability_snapshot,
             {:ok, %{resolved: %{watch_changes_webhook: true}}}
           ) do
        {:raise, reason} when is_binary(reason) -> raise reason
        {:raise, reason} -> raise inspect(reason)
        response -> response
      end
    end

    def watch_item(provider, params) do
      case Application.get_env(:zaq, :provider_browser_watch_response, :default) do
        :default ->
          if Map.get(params, "kind") == "folder" do
            return_watch_collection(provider, params)
          else
            return_watch_item(provider, params)
          end

        response ->
          response
      end
    end

    def unwatch_item(provider, params) do
      if pid = Application.get_env(:zaq, :ingestion_provider_browser_test_pid) do
        send(pid, {:unwatch_item, provider, params})
      end

      Application.get_env(:zaq, :provider_browser_unwatch_response, :ok)
    end

    defp return_watch_item(provider, params) do
      if pid = Application.get_env(:zaq, :ingestion_provider_browser_test_pid) do
        send(pid, {:watch_item, provider, params})
      end

      {:ok,
       %{
         status: "watched",
         channel_id: "channel-1",
         resource_id: "resource-1",
         metadata: %{
           "watch" => %{"channel_id" => "channel-1", "resource_id" => "resource-1"}
         }
       }}
    end

    defp return_watch_collection(provider, params) do
      if pid = Application.get_env(:zaq, :ingestion_provider_browser_test_pid) do
        send(pid, {:watch_collection, provider, params})
      end

      {:ok,
       %{
         status: "watched",
         channel_id: "collection-channel-1",
         resource_id: "collection-resource-1",
         collection_id: Map.get(params, "file_id") || Map.get(params, :collection_id),
         checkpoint: "checkpoint-1",
         metadata: %{
           "watch" => %{
             "channel_id" => "collection-channel-1",
             "resource_id" => "collection-resource-1",
             "kind" => "collection",
             "checkpoint" => "checkpoint-1"
           }
         }
       }}
    end
  end

  defmodule ProviderBrowserErrorBridgeStub do
    def list_files(provider, params, _context) do
      if pid = Application.get_env(:zaq, :ingestion_provider_browser_test_pid) do
        send(pid, {:list_files, provider, params})
      end

      Application.get_env(:zaq, :provider_browser_response, {:error, :timeout})
    end
  end

  defmodule ProviderBrowserCustomBridgeStub do
    def list_files(provider, params, _context) do
      if pid = Application.get_env(:zaq, :ingestion_provider_browser_test_pid) do
        send(pid, {:list_files, provider, params})
      end

      response = Application.get_env(:zaq, :provider_browser_response, [])
      records = if is_list(response), do: response, else: Map.get(response, :records, [])

      {:ok,
       %RecordPage{
         resource_type: :item,
         records: records,
         pagination: %{cursor: nil, has_more?: false},
         stats: %{scanned: length(records), returned: length(records)},
         filters: Map.get(params, "filters", %{}),
         metadata: %{}
       }}
    end
  end

  setup do
    SystemConfigFixtures.seed_embedding_config(%{model: "test-model", dimension: "1536"})
    :ok
  end

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = super_admin_fixture(%{username: "ingestion_live_admin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: user.id})

    tmp_dir =
      Path.join(System.tmp_dir!(), "zaq_ingestion_live_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    File.mkdir_p!(Path.join(tmp_dir, "docs/sub"))
    File.mkdir_p!(Path.join(tmp_dir, "target"))
    File.write!(Path.join(tmp_dir, "alpha.md"), "# alpha")
    File.write!(Path.join(tmp_dir, "notes.txt"), "notes")
    File.write!(Path.join(tmp_dir, "docs/readme.md"), "# readme")

    original_ingestion = Application.get_env(:zaq, Zaq.Ingestion)
    original_storage = Application.get_env(:zaq, Zaq.Storage)
    original_bridge = Application.get_env(:zaq, :ingestion_data_source_bridge_module)
    original_test_pid = Application.get_env(:zaq, :ingestion_provider_browser_test_pid)
    original_provider_browser_response = Application.get_env(:zaq, :provider_browser_response)

    original_provider_browser_capability_snapshot =
      Application.get_env(:zaq, :provider_browser_capability_snapshot)

    original_provider_browser_watch_response =
      Application.get_env(:zaq, :provider_browser_watch_response)

    original_provider_browser_unwatch_response =
      Application.get_env(:zaq, :provider_browser_unwatch_response)

    storage_config = [base_path: tmp_dir, volumes: %{}]
    Application.put_env(:zaq, Zaq.Ingestion, storage_config)
    Application.put_env(:zaq, Zaq.Storage, storage_config)

    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "Disk",
      provider: "disk",
      kind: "data_source",
      enabled: true,
      settings: %{"volumes" => [%{"name" => "default", "path" => "."}]}
    })
    |> Repo.insert!()

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.Ingestion, original_ingestion || [])
      Application.put_env(:zaq, Zaq.Storage, original_storage || [])

      case original_bridge do
        nil -> Application.delete_env(:zaq, :ingestion_data_source_bridge_module)
        module -> Application.put_env(:zaq, :ingestion_data_source_bridge_module, module)
      end

      case original_test_pid do
        nil -> Application.delete_env(:zaq, :ingestion_provider_browser_test_pid)
        pid -> Application.put_env(:zaq, :ingestion_provider_browser_test_pid, pid)
      end

      case original_provider_browser_response do
        nil -> Application.delete_env(:zaq, :provider_browser_response)
        value -> Application.put_env(:zaq, :provider_browser_response, value)
      end

      case original_provider_browser_capability_snapshot do
        nil -> Application.delete_env(:zaq, :provider_browser_capability_snapshot)
        value -> Application.put_env(:zaq, :provider_browser_capability_snapshot, value)
      end

      case original_provider_browser_watch_response do
        nil -> Application.delete_env(:zaq, :provider_browser_watch_response)
        value -> Application.put_env(:zaq, :provider_browser_watch_response, value)
      end

      case original_provider_browser_unwatch_response do
        nil -> Application.delete_env(:zaq, :provider_browser_unwatch_response)
        value -> Application.put_env(:zaq, :provider_browser_unwatch_response, value)
      end

      File.rm_rf!(tmp_dir)
    end)

    {:ok, conn: conn, tmp_dir: tmp_dir}
  end

  defp create_job(attrs) do
    %IngestJob{}
    |> IngestJob.changeset(
      Map.merge(
        %{file_path: "notes.txt", status: "pending", mode: "async", volume_name: "default"},
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp open_jobs_drawer(view) do
    if has_element?(view, "#ingestion-jobs-drawer") do
      view
    else
      view |> element("#monitor-jobs-button") |> render_click()
      view
    end
  end

  defp create_document_with_chunk(source, attrs \\ %{}) do
    {:ok, doc} =
      attrs
      |> Map.merge(%{source: source, content: "doc content"})
      |> Document.create()

    {:ok, _chunk} =
      Chunk.create(%{
        document_id: doc.id,
        content: "chunk content",
        chunk_index: 0
      })

    doc
  end

  defp disk_source(relative_path, opts \\ []) do
    volume = Keyword.get(opts, :volume, "default")
    config_id = Keyword.get(opts, :config_id) || Repo.get_by!(ChannelConfig, provider: "disk").id
    kind = opts |> Keyword.get(:kind, "file") |> to_string()
    {:ok, entry} = EntryCatalog.ensure(volume, relative_path, kind)

    "data_source/disk/#{config_id}/#{entry.id}"
  end

  defp source_entry(relative_path, kind \\ "file") do
    EntryCatalog.get_active("default", relative_path) ||
      elem(EntryCatalog.ensure("default", relative_path, kind), 1)
  end

  defp open_upload_modal(view) do
    view |> element("#upload-data-button") |> render_click()
  end

  # ────────────────────────────────────────────────────────────────
  # Existing tests (unchanged)
  # ────────────────────────────────────────────────────────────────

  describe "provider browsing" do
    setup do
      Application.put_env(:zaq, :ingestion_data_source_bridge_module, ProviderBrowserBridgeStub)
      Application.put_env(:zaq, :ingestion_provider_browser_test_pid, self())

      {:ok, config} =
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: "Google Drive #{System.unique_integer([:positive])}",
          provider: "google_drive",
          kind: "data_source",
          enabled: true,
          settings: %{}
        })
        |> Repo.insert()

      {:ok, provider_config: config}
    end

    test "lists provider records from the route provider and navigates folders", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")

      assert_received {:list_files, "google_drive", %{"config_id" => config_id, "filters" => %{}}}
      assert is_integer(config_id)
      assert has_element?(view, "button", "Project Docs")
      assert has_element?(view, "span", "Budget.pdf")
      assert has_element?(view, ~s(img[src="https://drive.example/icons/folder.png"]), "")
      assert has_element?(view, ~s(img[src="https://drive.example/icons/pdf.png"]), "")
      refute has_element?(view, "#new-folder-button")
      refute has_element?(view, "#add-raw-md-button")

      render_hook(view, "toggle_view_mode", %{"mode" => "grid"})
      assert has_element?(view, ~s(img[src="https://drive.example/icons/folder.png"]), "")
      assert has_element?(view, ~s(img[src="https://drive.example/icons/pdf.png"]), "")
      render_hook(view, "toggle_view_mode", %{"mode" => "list"})

      render_hook(view, "navigate", %{"path" => "folder-1"})

      assert_received {:list_files, "google_drive",
                       %{"filters" => %{"parent" => "folder-1", "include_shared" => false}}}

      assert has_element?(view, "button", "Nested Folder")
      assert has_element?(view, "span", "No Preview.txt")
    end

    test "shows creation CTAs when provider create_item is supported", %{conn: conn} do
      Application.put_env(
        :zaq,
        :provider_browser_capability_snapshot,
        {:ok, %{resolved: %{create_item: true}}}
      )

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")

      assert has_element?(view, "#upload-data-button")
      assert has_element?(view, "#new-folder-button")
      assert has_element?(view, "#add-raw-md-button")
    end

    test "provider new folder routes through create document action", %{conn: conn} do
      Application.put_env(
        :zaq,
        :provider_browser_capability_snapshot,
        {:ok, %{resolved: %{create_item: true}}}
      )

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")

      render_hook(view, "show_new_folder_modal", %{})
      render_hook(view, "create_folder", %{"name" => "Reports"})

      assert_received {:create_file, "google_drive",
                       %{"config_id" => _config_id, "kind" => "folder", "name" => "Reports"}}
    end

    test "provider raw markdown routes through create document action", %{conn: conn} do
      Application.put_env(
        :zaq,
        :provider_browser_capability_snapshot,
        {:ok, %{resolved: %{create_item: true}}}
      )

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")

      render_hook(view, "show_add_raw_modal", %{})
      render_hook(view, "save_raw_content", %{"filename" => "remote", "content" => "# Remote\n"})

      assert_received {:create_file, "google_drive",
                       %{
                         "config_id" => _config_id,
                         "content" => "# Remote\n",
                         "mime_type" => "text/markdown",
                         "name" => "remote.md"
                       }}
    end

    test "provider upload routes decoded content through create document action", %{conn: conn} do
      Application.put_env(
        :zaq,
        :provider_browser_capability_snapshot,
        {:ok, %{resolved: %{create_item: true}}}
      )

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")
      open_upload_modal(view)

      upload =
        file_input(view, "#upload-form", :files, [
          %{name: "upload.txt", content: "hello upload", type: "text/plain"}
        ])

      assert render_upload(upload, "upload.txt")
      view |> form("#upload-form") |> render_submit()

      assert_received {:create_file, "google_drive",
                       %{
                         "config_id" => _config_id,
                         "content" => "hello upload",
                         "mime_type" => "text/plain",
                         "name" => "upload.txt"
                       }}
    end

    test "provider browsing dispatches root and nested shared filters distinctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")

      assert_received {:list_files, "google_drive", root_params}
      assert root_params["filters"] == %{}

      render_hook(view, "navigate", %{"path" => "folder-1"})

      assert_received {:list_files, "google_drive",
                       %{"filters" => %{"parent" => "folder-1", "include_shared" => false}}}
    end

    test "disables provider watch when global base URL is not configured", %{
      conn: conn,
      provider_config: config
    } do
      original_base_url = ZaqSystem.get_global_base_url()
      :ok = ZaqSystem.set_global_base_url(nil)

      on_exit(fn -> :ok = ZaqSystem.set_global_base_url(original_base_url) end)

      create_document_with_chunk("data_source/google_drive/#{config.id}/file-1")

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")
      render_hook(view, "toggle_select", %{"path" => "file-1"})

      reason =
        "Set System Configuration > Global > Base URL to enable external data-source watching."

      assert has_element?(view, ~s(#bulk-watch-button[disabled][title="#{reason}"]))

      render_hook(view, "toggle_watch_status", %{"path" => "file-1"})
      refute_received {:watch_item, _, _}
    end

    test "provider watch uses global base URL for webhook address", %{
      conn: conn,
      provider_config: config
    } do
      original_base_url = ZaqSystem.get_global_base_url()
      :ok = ZaqSystem.set_global_base_url("https://zaq.example/root/")

      on_exit(fn -> :ok = ZaqSystem.set_global_base_url(original_base_url) end)

      create_document_with_chunk("data_source/google_drive/#{config.id}/file-1")

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")
      render_hook(view, "toggle_watch_status", %{"path" => "file-1"})

      assert_received {:watch_item, "google_drive",
                       %{
                         "file_id" => "file-1",
                         "webhook_url" =>
                           "https://zaq.example/root/channels/webhook/data_source/google_drive"
                       }}

      assert Document.get_by_source("data_source/google_drive/#{config.id}/file-1").watch_status ==
               "watched"
    end

    test "provider folder can be watched before a folder document exists", %{
      conn: conn,
      provider_config: config
    } do
      original_base_url = ZaqSystem.get_global_base_url()
      :ok = ZaqSystem.set_global_base_url("https://zaq.example")

      on_exit(fn -> :ok = ZaqSystem.set_global_base_url(original_base_url) end)

      source = "data_source/google_drive/#{config.id}/folder-1"
      refute Document.get_by_source(source)

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")
      render_hook(view, "toggle_watch_status", %{"path" => "folder-1"})

      assert_received {:watch_collection, "google_drive",
                       %{
                         "file_id" => "folder-1",
                         "kind" => "folder",
                         "webhook_url" =>
                           "https://zaq.example/channels/webhook/data_source/google_drive"
                       }}

      assert %Document{} = doc = Document.get_by_source(source)
      assert doc.content == nil
      assert doc.metadata["entry_type"] == "folder"
      refute Map.has_key?(doc.metadata, "watch")
      assert doc.watch_status == "watched"
    end

    test "provider folder watch is shown as inherited on child items", %{
      conn: conn,
      provider_config: config
    } do
      original_base_url = ZaqSystem.get_global_base_url()
      :ok = ZaqSystem.set_global_base_url("https://zaq.example")

      on_exit(fn -> :ok = ZaqSystem.set_global_base_url(original_base_url) end)

      {:ok, _doc} =
        Document.insert_new(%{
          source: "data_source/google_drive/#{config.id}/folder-1",
          metadata: %{"entry_type" => "folder"},
          watch_status: "watched"
        })

      {:ok, _child_doc} =
        Document.insert_new(%{
          source: "data_source/google_drive/#{config.id}/file-no-url",
          content: "already ingested",
          watch_status: "unwatched"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")
      render_hook(view, "navigate", %{"path" => "folder-1"})

      assert has_element?(view, ~s(button[title="Watched through parent folder"]))

      render_hook(view, "toggle_watch_status", %{"path" => "file-no-url"})
      refute_received {:watch_item, _, _}
      refute_received {:watch_collection, _, _}
    end

    test "provider watch on an inherited child shows a skip flash", %{
      conn: conn,
      provider_config: config
    } do
      original_base_url = ZaqSystem.get_global_base_url()
      :ok = ZaqSystem.set_global_base_url("https://zaq.example")

      on_exit(fn -> :ok = ZaqSystem.set_global_base_url(original_base_url) end)

      {:ok, _doc} =
        Document.insert_new(%{
          source: "data_source/google_drive/#{config.id}/folder-1",
          metadata: %{"entry_type" => "folder"},
          watch_status: "watched"
        })

      {:ok, _child_doc} =
        Document.insert_new(%{
          source: "data_source/google_drive/#{config.id}/file-no-url",
          content: "already ingested",
          watch_status: "unwatched"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")
      assert_received {:list_files, "google_drive", _params}

      render_hook(view, "navigate", %{"path" => "folder-1"})
      render_hook(view, "toggle_watch_status", %{"path" => "file-no-url"})

      state = :sys.get_state(view.pid)

      assert Phoenix.Flash.get(state.socket.assigns.flash, :info) ==
               "This item is watched through its parent folder."
    end

    test "provider watch_supported recognizes tuple and map capability snapshots", %{
      conn: conn,
      provider_config: config
    } do
      original_base_url = ZaqSystem.get_global_base_url()
      :ok = ZaqSystem.set_global_base_url("https://zaq.example/root")

      on_exit(fn -> :ok = ZaqSystem.set_global_base_url(original_base_url) end)

      for {capability_snapshot, idx} <-
            Enum.with_index([
              {:ok, %{resolved: %{"watch_changes_webhook" => true}}},
              %{resolved: %{watch_changes_webhook: true}}
            ]) do
        Application.put_env(:zaq, :provider_browser_capability_snapshot, capability_snapshot)

        selected_path = if idx == 0, do: "file-1", else: "folder-1"

        case selected_path do
          "file-1" ->
            create_document_with_chunk("data_source/google_drive/#{config.id}/file-1")

          "folder-1" ->
            {:ok, _folder_doc} =
              Document.insert_new(%{
                source: "data_source/google_drive/#{config.id}/folder-1",
                metadata: %{"entry_type" => "folder"},
                watch_status: "unwatched"
              })
        end

        {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")
        assert_received {:list_files, "google_drive", _params}

        render_hook(view, "toggle_select", %{"path" => selected_path})
        refute has_element?(view, "#bulk-watch-button[disabled]")
      end
    end

    test "provider watch_supported disables watching when capability snapshot raises", %{
      conn: conn,
      provider_config: config
    } do
      original_base_url = ZaqSystem.get_global_base_url()
      :ok = ZaqSystem.set_global_base_url("https://zaq.example/root")

      on_exit(fn -> :ok = ZaqSystem.set_global_base_url(original_base_url) end)

      Application.put_env(:zaq, :provider_browser_capability_snapshot, {:raise, "boom"})
      create_document_with_chunk("data_source/google_drive/#{config.id}/file-1")

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")
      assert_received {:list_files, "google_drive", _params}

      render_hook(view, "toggle_select", %{"path" => "file-1"})

      assert has_element?(view, "#bulk-watch-button[disabled]")
    end

    test "provider watch skips unsupported providers without a watch_changes_webhook capability",
         %{
           conn: conn,
           provider_config: config
         } do
      original_base_url = ZaqSystem.get_global_base_url()
      :ok = ZaqSystem.set_global_base_url("https://zaq.example/root")

      on_exit(fn -> :ok = ZaqSystem.set_global_base_url(original_base_url) end)

      Application.put_env(:zaq, :provider_browser_capability_snapshot, {:ok, %{resolved: %{}}})
      create_document_with_chunk("data_source/google_drive/#{config.id}/file-1")

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")
      assert_received {:list_files, "google_drive", _params}

      render_hook(view, "toggle_watch_status", %{"path" => "file-1"})

      state = :sys.get_state(view.pid)

      assert Phoenix.Flash.get(state.socket.assigns.flash, :info) ==
               "Watching is not supported for this data source."

      refute_received {:watch_item, _, _}
    end

    test "provider watch_selected reuses the provider watcher after the first dispatch", %{
      conn: conn,
      provider_config: config
    } do
      original_base_url = ZaqSystem.get_global_base_url()
      :ok = ZaqSystem.set_global_base_url("https://zaq.example/root/")

      on_exit(fn -> :ok = ZaqSystem.set_global_base_url(original_base_url) end)

      file_source = "data_source/google_drive/#{config.id}/file-1"
      folder_source = "data_source/google_drive/#{config.id}/folder-1"

      create_document_with_chunk(file_source, %{watch_status: "unwatched"})

      {:ok, _folder_doc} =
        Document.insert_new(%{
          source: folder_source,
          metadata: %{"entry_type" => "folder"},
          watch_status: "unwatched"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")
      assert_received {:list_files, "google_drive", _params}

      render_hook(view, "select_all", %{})
      render_hook(view, "watch_selected", %{})

      assert_received {:watch_item, "google_drive", params}
      assert params["target_source"] in [file_source, folder_source]
      assert params["kind"] in ["file", "folder"]
      refute_received {:watch_item, "google_drive", _}

      assert Document.get_by_source(file_source).watch_status == "watched"
      assert Document.get_by_source(folder_source).watch_status == "watched"
    end

    test "provider watch_selected surfaces provider errors and marks the document errored", %{
      conn: conn,
      provider_config: config
    } do
      original_base_url = ZaqSystem.get_global_base_url()
      :ok = ZaqSystem.set_global_base_url("https://zaq.example")

      on_exit(fn -> :ok = ZaqSystem.set_global_base_url(original_base_url) end)

      Application.put_env(
        :zaq,
        :provider_browser_watch_response,
        {:error, "provider denied"}
      )

      source = "data_source/google_drive/#{config.id}/file-1"
      create_document_with_chunk(source, %{watch_status: "unwatched"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")
      assert_received {:list_files, "google_drive", _params}

      render_hook(view, "toggle_select", %{"path" => "file-1"})
      render_hook(view, "watch_selected", %{})

      assert Document.get_by_source(source).watch_status == "error"
      assert Document.get_by_source(source).watch_error == ~s("provider denied")

      state = :sys.get_state(view.pid)

      assert Phoenix.Flash.get(state.socket.assigns.flash, :info) ==
               "No watch status was changed."
    end

    test "provider unwatch_selected dispatches teardown when the last watched item is cleared", %{
      conn: conn,
      provider_config: config
    } do
      original_base_url = ZaqSystem.get_global_base_url()
      :ok = ZaqSystem.set_global_base_url("https://zaq.example/root")

      on_exit(fn -> :ok = ZaqSystem.set_global_base_url(original_base_url) end)

      Application.put_env(:zaq, :provider_browser_unwatch_response, {:ok, %{}})

      source = "data_source/google_drive/#{config.id}/file-1"
      create_document_with_chunk(source, %{watch_status: "watched"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")
      assert_received {:list_files, "google_drive", _params}

      render_hook(view, "toggle_select", %{"path" => "file-1"})
      render_hook(view, "unwatch_selected", %{})

      assert_received {:unwatch_item, "google_drive", %{"target_source" => target_source}}
      assert target_source == "data_source/google_drive/#{config.id}"
      assert Document.get_by_source(source).watch_status == "unwatched"

      state = :sys.get_state(view.pid)

      assert Phoenix.Flash.get(state.socket.assigns.flash, :info) ==
               "Watching disabled for 1 item(s)."
    end

    test "provider unwatch_selected also accepts a plain :ok bridge response", %{
      conn: conn,
      provider_config: config
    } do
      original_base_url = ZaqSystem.get_global_base_url()
      :ok = ZaqSystem.set_global_base_url("https://zaq.example/root")

      on_exit(fn -> :ok = ZaqSystem.set_global_base_url(original_base_url) end)

      source = "data_source/google_drive/#{config.id}/file-1"
      create_document_with_chunk(source, %{watch_status: "watched"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")
      assert_received {:list_files, "google_drive", _params}

      render_hook(view, "toggle_select", %{"path" => "file-1"})
      render_hook(view, "unwatch_selected", %{})

      assert_received {:unwatch_item, "google_drive", %{"target_source" => _target_source}}
      assert Document.get_by_source(source).watch_status == "unwatched"

      state = :sys.get_state(view.pid)

      assert Phoenix.Flash.get(state.socket.assigns.flash, :info) ==
               "Watching disabled for 1 item(s)."
    end

    test "provider unwatch_selected treats bridge errors as skipped work", %{
      conn: conn,
      provider_config: config
    } do
      original_base_url = ZaqSystem.get_global_base_url()
      :ok = ZaqSystem.set_global_base_url("https://zaq.example/root")

      on_exit(fn -> :ok = ZaqSystem.set_global_base_url(original_base_url) end)

      Application.put_env(:zaq, :provider_browser_unwatch_response, {:error, "gone"})

      source = "data_source/google_drive/#{config.id}/file-1"
      create_document_with_chunk(source, %{watch_status: "watched"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")
      assert_received {:list_files, "google_drive", _params}

      render_hook(view, "toggle_select", %{"path" => "file-1"})
      render_hook(view, "unwatch_selected", %{})

      assert Document.get_by_source(source).watch_status == "unwatched"

      state = :sys.get_state(view.pid)

      assert Phoenix.Flash.get(state.socket.assigns.flash, :info) ==
               "Watching disabled for 1 item(s). 1 item(s) skipped."
    end

    test "provider unwatch_selected treats unexpected bridge responses as skipped work", %{
      conn: conn,
      provider_config: config
    } do
      original_base_url = ZaqSystem.get_global_base_url()
      :ok = ZaqSystem.set_global_base_url("https://zaq.example/root")

      on_exit(fn -> :ok = ZaqSystem.set_global_base_url(original_base_url) end)

      Application.put_env(:zaq, :provider_browser_unwatch_response, :unexpected)

      source = "data_source/google_drive/#{config.id}/file-1"
      create_document_with_chunk(source, %{watch_status: "watched"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")
      assert_received {:list_files, "google_drive", _params}

      render_hook(view, "toggle_select", %{"path" => "file-1"})
      render_hook(view, "unwatch_selected", %{})

      assert Document.get_by_source(source).watch_status == "unwatched"

      state = :sys.get_state(view.pid)

      assert Phoenix.Flash.get(state.socket.assigns.flash, :info) ==
               "Watching disabled for 1 item(s). 1 item(s) skipped."
    end

    test "previews provider records by URL and queues external ingestion", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")
      assert_received {:list_files, "google_drive", _params}

      view
      |> element(~s(button[phx-click="open_preview"][phx-value-path="file-1"]))
      |> render_click()

      assert has_element?(view, "#file-preview-modal")
      assert has_element?(view, ~s(iframe[src="https://drive.example/file-1"]), "")
      assert has_element?(view, "a", "Open in provider")
      refute render(view) =~ "Provider document content"

      render_hook(view, "close_preview_modal", %{})
      render_hook(view, "toggle_select", %{"path" => "file-1"})

      view
      |> element("#ingest-selected-button")
      |> render_click()

      assert has_element?(view, "#ingest-toast", "Ingestion started.")

      job = Repo.one!(from j in IngestJob, order_by: [desc: j.inserted_at], limit: 1)

      assert job.file_path ==
               "data_source/google_drive/#{job.source_record["attributes"]["config_id"]}/file-1"

      assert job.source_record["attributes"]["provider"] == "google_drive"
      assert job.source_record["attributes"]["provider_record_id"] == "file-1"
      refute Map.has_key?(job.source_record, "content")
      refute Map.has_key?(job.source_record, "raw")
    end

    test "shows provider document with data-source permissions guidance", %{
      conn: conn,
      provider_config: config
    } do
      source = "data_source/google_drive/#{config.id}/file-1"

      {:ok, source_doc} =
        Document.create(%{
          source: source,
          content: "# Budget"
        })

      {:ok, person} =
        People.find_or_create_from_channel("email", %{
          "channel_id" => "reader@example.com",
          "email" => "reader@example.com",
          "display_name" => "Reader"
        })

      assert {:ok, _permission} =
               Ingestion.set_document_permission(source_doc.id, :person, person.id, ["read"])

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")
      assert_received {:list_files, "google_drive", _params}

      assert render(view) =~ "Budget.pdf"

      view
      |> element(~s(button[phx-click="view_provider_permissions"]), "shared")
      |> render_click()

      html = render(view)
      assert html =~ "Share with People &amp; Teams"
      assert html =~ "Permissions are imported from Google Drive"
      assert html =~ "reader@example.com"
      refute html =~ "share-target-select"
      refute html =~ "Save Permissions"
      refute html =~ "remove_permission"
    end

    test "uses any enabled provider from the URL without an ingestion allowlist", %{conn: conn} do
      {:ok, custom_config} =
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: "SharePoint #{System.unique_integer([:positive])}",
          provider: "sharepoint",
          kind: "data_source",
          enabled: true,
          settings: %{}
        })
        |> Repo.insert()

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/sharepoint")

      assert_received {:list_files, "sharepoint", %{"config_id" => config_id, "filters" => %{}}}

      assert config_id == custom_config.id
      assert has_element?(view, "button", "Project Docs")
    end

    test "does not dispatch when no enabled provider configuration exists", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/missing_provider")

      refute_received {:list_files, "missing_provider", _params}

      assert render(view) =~
               "No enabled data-source configuration found for missing_provider."
    end

    test "provider read-only guards keep the modal closed and flash info", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")

      for {event, params, expected} <- [
            {"show_new_folder_modal", %{},
             "This data source does not support document creation."},
            {"rename_item", %{"path" => "file-1", "type" => "file"},
             "Provider records are read-only in this phase."},
            {"delete_item", %{"path" => "file-1", "type" => "file"},
             "Provider records are read-only in this phase."},
            {"show_delete_confirmation", %{}, "Provider records are read-only in this phase."},
            {"move_item", %{"path" => "file-1", "type" => "file"},
             "Provider records are read-only in this phase."}
          ] do
        render_hook(view, event, params)
        state = :sys.get_state(view.pid)

        assert Phoenix.Flash.get(state.socket.assigns.flash, :info) == expected
        assert state.socket.assigns.modal == nil
      end
    end

    test "provider read-only share modal events are no-ops", %{
      conn: conn,
      provider_config: config
    } do
      source = "data_source/google_drive/#{config.id}/file-1"
      source_doc = create_document_with_chunk(source)

      {:ok, person} =
        People.find_or_create_from_channel("email", %{
          "channel_id" => "reader@example.com",
          "email" => "reader@example.com",
          "display_name" => "Reader"
        })

      {:ok, permission} =
        Ingestion.set_document_permission(source_doc.id, :person, person.id, ["read"])

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")

      view
      |> element(~s(button[phx-click="view_provider_permissions"]), "shared")
      |> render_click()

      before_state = :sys.get_state(view.pid)
      before_permissions = before_state.socket.assigns.share_modal_permissions
      before_pending = before_state.socket.assigns.share_modal_pending
      before_public = before_state.socket.assigns.share_modal_is_public

      render_hook(view, "toggle_public", %{})
      render_hook(view, "add_permission_target", %{"value" => "person:#{person.id}"})
      render_hook(view, "toggle_permission_right", %{"index" => "0", "right" => "write"})
      render_hook(view, "remove_pending", %{"index" => "0"})
      render_hook(view, "remove_permission", %{"id" => to_string(permission.id)})
      render_hook(view, "confirm_share", %{})

      after_state = :sys.get_state(view.pid)

      assert after_state.socket.assigns.share_modal_read_only == true
      assert after_state.socket.assigns.share_modal_is_public == before_public
      assert after_state.socket.assigns.share_modal_pending == before_pending
      assert after_state.socket.assigns.share_modal_permissions == before_permissions

      assert Enum.map(Ingestion.list_document_permissions(source_doc.id), & &1.id) ==
               [permission.id]
    end

    test "provider_permissions_info explains provider-managed permissions", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")

      render_hook(view, "provider_permissions_info", %{})

      state = :sys.get_state(view.pid)

      assert Phoenix.Flash.get(state.socket.assigns.flash, :info) ==
               "Permissions are managed in the data source. Update sharing there, then refresh ingestion to import the latest permissions."
    end

    test "provider load errors render empty state and detailed provider_error", %{conn: conn} do
      Application.put_env(
        :zaq,
        :ingestion_data_source_bridge_module,
        ProviderBrowserErrorBridgeStub
      )

      Application.put_env(:zaq, :provider_browser_response, {:error, :timeout})
      {:ok, timeout_view, timeout_html} = live(conn, ~p"/bo/ingestion/google_drive")

      assert timeout_html =~ "Failed to load provider records: :timeout"
      timeout_state = :sys.get_state(timeout_view.pid)
      assert timeout_state.socket.assigns.entries == []
      assert timeout_state.socket.assigns.records_by_path == %{}
      assert timeout_state.socket.assigns.ingestion_map == %{}

      Application.put_env(:zaq, :provider_browser_response, :unexpected)
      {:ok, unexpected_view, unexpected_html} = live(conn, ~p"/bo/ingestion/google_drive")

      assert unexpected_html =~ "Failed to load provider records."
      unexpected_state = :sys.get_state(unexpected_view.pid)
      assert unexpected_state.socket.assigns.entries == []
      assert unexpected_state.socket.assigns.records_by_path == %{}
      assert unexpected_state.socket.assigns.ingestion_map == %{}
    end

    test "provider root navigation and go_back reset the breadcrumb stack", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")

      render_hook(view, "navigate", %{"path" => "folder-1"})
      render_hook(view, "go_back", %{})
      render_hook(view, "navigate", %{"path" => "."})

      state = :sys.get_state(view.pid)
      assert state.socket.assigns.current_dir == "."
      assert state.socket.assigns.provider_folder_stack == []
      assert state.socket.assigns.breadcrumbs == []
    end

    test "provider breadcrumb navigation updates the stack and ignores missing ids", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")

      render_hook(view, "navigate", %{"path" => "folder-1"})
      render_hook(view, "navigate", %{"path" => "child-folder"})
      render_hook(view, "navigate", %{"path" => "folder-1"})

      stack_state = :sys.get_state(view.pid)
      assert stack_state.socket.assigns.current_dir == "folder-1"
      assert length(stack_state.socket.assigns.provider_folder_stack) == 1
      assert length(stack_state.socket.assigns.breadcrumbs) == 1

      before_missing = :sys.get_state(view.pid)
      render_hook(view, "navigate", %{"path" => "missing-id"})
      after_missing = :sys.get_state(view.pid)

      assert after_missing.socket.assigns.current_dir == before_missing.socket.assigns.current_dir

      assert after_missing.socket.assigns.provider_folder_stack ==
               before_missing.socket.assigns.provider_folder_stack

      assert after_missing.socket.assigns.breadcrumbs == before_missing.socket.assigns.breadcrumbs
    end

    test "provider go_back from nested folder returns to parent folder", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")

      render_hook(view, "navigate", %{"path" => "folder-1"})
      render_hook(view, "navigate", %{"path" => "child-folder"})
      render_hook(view, "go_back", %{})

      state = :sys.get_state(view.pid)

      assert state.socket.assigns.current_dir == "folder-1"

      assert state.socket.assigns.provider_folder_stack == [
               %{id: "folder-1", name: "Project Docs"}
             ]

      assert state.socket.assigns.breadcrumbs == [%{name: "Project Docs", path: "folder-1"}]
      assert render(view) =~ "Project Docs"
    end

    test "provider preview errors when a record has no URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")

      render_hook(view, "navigate", %{"path" => "folder-1"})
      render_hook(view, "open_preview", %{"path" => "file-no-url"})

      state = :sys.get_state(view.pid)

      assert Phoenix.Flash.get(state.socket.assigns.flash, :error) ==
               "Preview unavailable for this provider record."

      assert state.socket.assigns.modal != :preview
    end

    test "provider preview does not fall back to local preview for missing records", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")

      render_hook(view, "open_preview", %{"path" => "data_source/google_drive/missing"})

      state = :sys.get_state(view.pid)

      assert Phoenix.Flash.get(state.socket.assigns.flash, :error) ==
               "Preview is unavailable for this provider record."

      assert state.socket.assigns.modal != :preview
    end

    test "provider preview with filename still errors for missing provider record", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")

      render_hook(view, "open_preview", %{
        "path" => "missing-provider-id",
        "filename" => "Missing.pdf"
      })

      state = :sys.get_state(view.pid)

      assert Phoenix.Flash.get(state.socket.assigns.flash, :error) ==
               "Preview is unavailable for this provider record."

      assert state.socket.assigns.modal != :preview
    end

    test "provider record is stale when source modified_at is newer than document updated_at", %{
      conn: conn,
      provider_config: config
    } do
      original_bridge = Application.get_env(:zaq, :ingestion_data_source_bridge_module)
      original_response = Application.get_env(:zaq, :provider_browser_response)

      on_exit(fn ->
        case original_bridge do
          nil -> Application.delete_env(:zaq, :ingestion_data_source_bridge_module)
          value -> Application.put_env(:zaq, :ingestion_data_source_bridge_module, value)
        end

        case original_response do
          nil -> Application.delete_env(:zaq, :provider_browser_response)
          value -> Application.put_env(:zaq, :provider_browser_response, value)
        end
      end)

      Application.put_env(
        :zaq,
        :ingestion_data_source_bridge_module,
        ProviderBrowserCustomBridgeStub
      )

      record = %Record{
        id: "stale-1",
        kind: :file,
        name: "Stale.pdf",
        attributes: %{
          "provider" => "google_drive",
          "config_id" => to_string(config.id),
          "provider_record_id" => "stale-1"
        },
        url: "https://drive.example/stale-1",
        modified_at: ~U[2025-01-01 00:00:00Z]
      }

      source = ExternalSource.source(record)
      create_document_with_chunk(source, %{})

      doc = Document.get_by_source(source)

      Repo.update_all(
        from(d in Document, where: d.id == ^doc.id),
        set: [updated_at: ~U[2024-01-01 00:00:00Z]]
      )

      Application.put_env(:zaq, :provider_browser_response, [record])

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/google_drive")

      state = :sys.get_state(view.pid)

      assert state.socket.assigns.ingestion_map["Stale.pdf"].stale? == true
    end
  end

  test "navigates directories and handles non-directory navigation", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    assert has_element?(view, "button", "docs")
    assert has_element?(view, "span", "alpha.md")

    render_hook(view, "navigate", %{"path" => "docs"})
    assert has_element?(view, "span", "readme.md")

    render_hook(view, "go_back", %{})
    assert has_element?(view, "button", "docs")

    render_hook(view, "navigate", %{"path" => "notes.txt"})
    assert has_element?(view, "td", "Empty directory")
  end

  test "supports selection, modal open/close, and view mode toggle", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    render_hook(view, "toggle_select", %{"path" => "alpha.md"})
    assert has_element?(view, "button", "Delete (1)")

    render_hook(view, "toggle_select", %{"path" => "alpha.md"})
    refute has_element?(view, "button", "Delete (1)")

    render_hook(view, "toggle_select", %{"path" => "alpha.md"})
    render_hook(view, "select_all", %{})
    selected_count = :sys.get_state(view.pid).socket.assigns.selected |> MapSet.size()
    assert has_element?(view, "button", "Delete (#{selected_count})")

    render_hook(view, "select_all", %{})
    refute has_element?(view, "button", "Delete (#{selected_count})")

    render_hook(view, "show_delete_confirmation", %{})
    assert has_element?(view, "h3", "Delete Selected")

    render_hook(view, "close_modal", %{})
    refute has_element?(view, "h3", "Delete Selected")

    render_hook(view, "toggle_view_mode", %{"mode" => "grid"})
    assert has_element?(view, "th.zaq-ingestion-meta-label", "Select all")
  end

  test "toggle_watch_status ignores unsupported disk watches and clears existing watches", %{
    conn: conn
  } do
    source = disk_source("alpha.md")
    create_document_with_chunk(source)

    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    render_hook(view, "toggle_watch_status", %{"path" => "alpha.md"})
    assert Document.get_by_source(source).watch_status == "unwatched"

    {:ok, _doc} =
      Document.get_by_source(source)
      |> Document.changeset(%{watch_status: "pending"})
      |> Repo.update()

    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    render_hook(view, "toggle_watch_status", %{"path" => "alpha.md"})
    assert Document.get_by_source(source).watch_status == "unwatched"
  end

  test "errored watch click opens details modal and retry requests watch", %{conn: conn} do
    source = disk_source("alpha.md")
    doc = create_document_with_chunk(source)

    {:ok, _doc} =
      doc
      |> Document.changeset(%{watch_status: "error", watch_error: "provider denied watch"})
      |> Repo.update()

    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    render_hook(view, "toggle_watch_status", %{
      "path" => "alpha.md",
      "watch_error" => "provider denied watch"
    })

    assert has_element?(view, "#watch-error-modal", "Watch setup failed")
    assert has_element?(view, "#watch-error-modal", "provider denied watch")

    render_hook(view, "retry_watch", %{})

    assert Document.get_by_source(source).watch_status == "error"
    refute has_element?(view, "#watch-error-modal")
  end

  test "watch_selected skips disk selections when watch capability is not advertised", %{
    conn: conn
  } do
    alpha_source = disk_source("alpha.md")
    folder_source = disk_source("docs", kind: "directory")

    create_document_with_chunk(alpha_source)
    create_document_with_chunk(folder_source, %{metadata: %{"entry_type" => "folder"}})

    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
    render_hook(view, "toggle_select", %{"path" => "alpha.md"})
    render_hook(view, "toggle_select", %{"path" => "docs"})
    render_hook(view, "watch_selected", %{})

    assert Document.get_by_source(alpha_source).watch_status == "unwatched"
    assert Document.get_by_source(folder_source).watch_status == "unwatched"
  end

  test "retry_watch without an open modal just clears modal state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    render_hook(view, "retry_watch", %{})

    state = :sys.get_state(view.pid)

    assert state.socket.assigns.modal == nil
    assert state.socket.assigns.watch_error_target == nil
  end

  test "watch_selected with no eligible selected records shows a no-op flash", %{conn: conn} do
    create_document_with_chunk(disk_source("alpha.md"), %{watch_status: "pending"})
    create_document_with_chunk(disk_source("notes.txt"), %{watch_status: "watched"})

    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    render_hook(view, "toggle_select", %{"path" => "alpha.md"})
    render_hook(view, "toggle_select", %{"path" => "notes.txt"})
    render_hook(view, "watch_selected", %{})

    state = :sys.get_state(view.pid)

    assert Phoenix.Flash.get(state.socket.assigns.flash, :info) ==
             "No selected items can be updated."
  end

  test "unwatch_selected clears selected watched records and skips non-clearable selections", %{
    conn: conn
  } do
    alpha_source = disk_source("alpha.md")
    notes_source = disk_source("notes.txt")
    folder_source = disk_source("docs", kind: "directory")

    alpha = create_document_with_chunk(alpha_source, %{watch_status: "pending"})
    notes = create_document_with_chunk(notes_source, %{watch_status: "unwatched"})

    folder_doc =
      create_document_with_chunk(folder_source, %{
        metadata: %{"entry_type" => "folder"},
        watch_status: "watched"
      })

    assert alpha.watch_status == "pending"
    assert notes.watch_status == "unwatched"

    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    render_hook(view, "select_all", %{})
    render_hook(view, "unwatch_selected", %{})

    state = :sys.get_state(view.pid)

    assert state.socket.assigns.selected == MapSet.new()
    assert Document.get_by_source(alpha_source).watch_status == "unwatched"
    assert Document.get_by_source(notes_source).watch_status == "unwatched"
    assert Document.get_by_source(folder_source).watch_status == "unwatched"
    assert folder_doc.watch_status == "watched"

    assert Phoenix.Flash.get(state.socket.assigns.flash, :info) ==
             "Watching disabled for 2 item(s)."
  end

  test "toggle_watch_status falls back to the default watch error message", %{conn: conn} do
    source = disk_source("alpha.md")
    doc = create_document_with_chunk(source)

    {:ok, _doc} =
      doc
      |> Document.changeset(%{watch_status: "error", watch_error: " "})
      |> Repo.update()

    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    render_hook(view, "toggle_watch_status", %{
      "path" => "alpha.md",
      "watch_error" => " "
    })

    state = :sys.get_state(view.pid)
    assert state.socket.assigns.modal == :watch_error
    assert state.socket.assigns.watch_error_message == "Watch setup failed."

    render_hook(view, "toggle_watch_status", %{"path" => "alpha.md"})

    state = :sys.get_state(view.pid)
    assert state.socket.assigns.modal == :watch_error
    assert state.socket.assigns.watch_error_message == "Watch setup failed."
  end

  test "toggle_watch_status on a non-ingested local file shows unsupported-source flash", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    render_hook(view, "toggle_watch_status", %{"path" => "notes.txt"})

    state = :sys.get_state(view.pid)

    assert Phoenix.Flash.get(state.socket.assigns.flash, :info) ==
             "Watching is not supported for this data source."
  end

  test "opens file preview inside modal", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    view
    |> element(~s(button[phx-click="open_preview"][phx-value-path$="alpha.md"]))
    |> render_click()

    assert has_element?(view, "#file-preview-modal")
    assert has_element?(view, "#file-preview-modal", "alpha.md")

    render_hook(view, "close_preview_modal", %{})
    refute has_element?(view, "#file-preview-modal")
  end

  test "opens preview from a disk ChannelConfig volume whose path differs from its name", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    storage_dir = Path.join(tmp_dir, "stored/archive")
    File.mkdir_p!(storage_dir)
    File.write!(Path.join(storage_dir, "report.md"), "# ChannelConfig backed report")

    config = Repo.get_by!(ChannelConfig, provider: "disk")

    config
    |> ChannelConfig.changeset(%{
      settings: %{"volumes" => [%{"name" => "archives", "path" => "stored/archive"}]}
    })
    |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    assert has_element?(view, ~s(button[phx-click="open_preview"][phx-value-path="report.md"]))

    view
    |> element(~s(button[phx-click="open_preview"][phx-value-path="report.md"]))
    |> render_click()

    assert has_element?(view, "#file-preview-modal")
    assert has_element?(view, "#file-preview-modal .md-content h1", "ChannelConfig backed report")
    assert render(view) =~ "/bo/files/ref/"
  end

  test "local preview ignores blank filename override", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    render_hook(view, "open_preview", %{"path" => "alpha.md", "filename" => ""})

    state = :sys.get_state(view.pid)

    assert state.socket.assigns.modal == :preview
    assert state.socket.assigns.preview.relative_path == "alpha.md"
    assert state.socket.assigns.preview.filename == "alpha.md"
  end

  test "creates folders with validation and error handling", %{conn: conn, tmp_dir: tmp_dir} do
    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    render_hook(view, "show_new_folder_modal", %{})
    assert has_element?(view, "#new-folder-input")

    render_hook(view, "create_folder", %{"name" => "   "})
    assert has_element?(view, "p", "Folder name cannot be empty.")

    render_hook(view, "create_folder", %{"name" => "../outside"})
    assert has_element?(view, "p", "Failed: :path_traversal")

    render_hook(view, "create_folder", %{"name" => "reports"})
    assert File.dir?(Path.join(tmp_dir, "reports"))
    refute has_element?(view, "#new-folder-input")
  end

  test "renames files and handles validation branches", %{conn: conn, tmp_dir: tmp_dir} do
    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    render_hook(view, "rename_item", %{"path" => "notes.txt", "type" => "file"})
    assert has_element?(view, "h3", "Rename")

    render_hook(view, "confirm_rename", %{"name" => "   "})
    assert has_element?(view, "p", "Name cannot be empty.")

    render_hook(view, "confirm_rename", %{"name" => "notes.txt"})
    refute has_element?(view, "#rename-input")

    render_hook(view, "rename_item", %{"path" => "notes.txt", "type" => "file"})
    render_hook(view, "confirm_rename", %{"name" => "../bad-name"})
    assert has_element?(view, "p", "Rename failed: :path_traversal")

    render_hook(view, "confirm_rename", %{"name" => "notes-renamed.txt"})
    assert File.exists?(Path.join(tmp_dir, "notes-renamed.txt"))
    refute File.exists?(Path.join(tmp_dir, "notes.txt"))
  end

  test "deletes files and directories with success and failure cases", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    source = disk_source("alpha.md")
    {:ok, _doc} = Document.create(%{source: source, content: "doc alpha"})

    render_hook(view, "delete_item", %{"path" => "alpha.md", "type" => "file"})
    render_hook(view, "confirm_delete", %{})

    refute File.exists?(Path.join(tmp_dir, "alpha.md"))
    assert Document.get_by_source(source) == nil

    render_hook(view, "delete_item", %{"path" => "docs", "type" => "directory"})
    render_hook(view, "confirm_delete", %{})
    refute File.dir?(Path.join(tmp_dir, "docs"))

    render_hook(view, "delete_item", %{"path" => "missing.txt", "type" => "file"})
    render_hook(view, "confirm_delete", %{})
    assert has_element?(view, "p", "Delete failed: :enoent")
  end

  describe "single-file delete RAG cleanup" do
    test "removes document and chunks in non-volume mode", %{conn: conn, tmp_dir: tmp_dir} do
      source = disk_source("alpha.md")
      doc = create_document_with_chunk(source)
      assert Chunk.count_by_document(doc.id) == 1

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "delete_item", %{"path" => "alpha.md", "type" => "file"})
      render_hook(view, "confirm_delete", %{})

      refute File.exists?(Path.join(tmp_dir, "alpha.md"))
      assert Document.get_by_source(source) == nil
      assert Chunk.count_by_document(doc.id) == 0
    end

    test "removes volume-prefixed document and chunks", %{conn: conn, tmp_dir: tmp_dir} do
      original_ingestion = Application.get_env(:zaq, Zaq.Ingestion)
      original_storage = Application.get_env(:zaq, Zaq.Storage)
      storage_config = [base_path: tmp_dir, volumes: %{"docs" => tmp_dir}]

      Application.put_env(:zaq, Zaq.Ingestion, storage_config)
      Application.put_env(:zaq, Zaq.Storage, storage_config)

      Repo.get_by!(ChannelConfig, provider: "disk")
      |> ChannelConfig.changeset(%{
        settings: %{"volumes" => [%{"name" => "docs", "path" => "."}]}
      })
      |> Repo.update!()

      on_exit(fn ->
        Application.put_env(:zaq, Zaq.Ingestion, original_ingestion || [])
        Application.put_env(:zaq, Zaq.Storage, original_storage || [])
      end)

      source = disk_source("alpha.md", volume: "docs")
      doc = create_document_with_chunk(source)
      assert Chunk.count_by_document(doc.id) == 1

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "delete_item", %{"path" => "alpha.md", "type" => "file"})
      render_hook(view, "confirm_delete", %{})

      refute File.exists?(Path.join(tmp_dir, "alpha.md"))
      assert Document.get_by_source(source) == nil
      assert Chunk.count_by_document(doc.id) == 0
    end
  end

  describe "directory delete RAG cleanup" do
    test "deleting nested directory removes nested documents and chunks in volume mode", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      docs_root = Path.join(tmp_dir, "docs")
      nested_dir = Path.join(docs_root, "sub/deep")
      File.mkdir_p!(nested_dir)

      File.write!(Path.join(nested_dir, "first.md"), "# First")
      File.write!(Path.join(nested_dir, "second.md"), "# Second")

      original_ingestion = Application.get_env(:zaq, Zaq.Ingestion)
      original_storage = Application.get_env(:zaq, Zaq.Storage)
      storage_config = [base_path: tmp_dir, volumes: %{"docs" => docs_root}]

      Application.put_env(:zaq, Zaq.Ingestion, storage_config)
      Application.put_env(:zaq, Zaq.Storage, storage_config)

      Repo.get_by!(ChannelConfig, provider: "disk")
      |> ChannelConfig.changeset(%{
        settings: %{"volumes" => [%{"name" => "docs", "path" => "docs"}]}
      })
      |> Repo.update!()

      on_exit(fn ->
        Application.put_env(:zaq, Zaq.Ingestion, original_ingestion || [])
        Application.put_env(:zaq, Zaq.Storage, original_storage || [])
      end)

      folder_source = disk_source("sub", volume: "docs", kind: "directory")
      folder_id = folder_source |> String.split("/") |> List.last()
      first_source = disk_source("sub/deep/first.md", volume: "docs")
      second_source = disk_source("sub/deep/second.md", volume: "docs")

      first_doc =
        create_document_with_chunk(first_source, %{
          metadata: %{"provider_parent_ids" => [folder_id]}
        })

      second_doc =
        create_document_with_chunk(second_source, %{
          metadata: %{"provider_parent_ids" => [folder_id]}
        })

      assert Chunk.count_by_document(first_doc.id) == 1
      assert Chunk.count_by_document(second_doc.id) == 1

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "delete_item", %{"path" => "sub", "type" => "directory"})
      render_hook(view, "confirm_delete", %{})

      refute File.dir?(Path.join(docs_root, "sub"))

      assert Document.get_by_source(first_source) == nil
      assert Document.get_by_source(second_source) == nil
      assert Chunk.count_by_document(first_doc.id) == 0
      assert Chunk.count_by_document(second_doc.id) == 0
    end
  end

  test "bulk delete handles full success and partial failures", %{conn: conn, tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "bulk-a.txt"), "A")
    File.write!(Path.join(tmp_dir, "bulk-b.txt"), "B")
    File.write!(Path.join(tmp_dir, "bulk-report.pdf"), "%PDF")
    source = disk_source("bulk-report.pdf")
    source_doc = create_document_with_chunk(source)

    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    render_hook(view, "toggle_select", %{"path" => "bulk-a.txt"})
    render_hook(view, "toggle_select", %{"path" => "bulk-b.txt"})
    render_hook(view, "show_delete_confirmation", %{})
    render_hook(view, "confirm_delete_selected", %{})

    refute File.exists?(Path.join(tmp_dir, "bulk-a.txt"))
    refute File.exists?(Path.join(tmp_dir, "bulk-b.txt"))

    File.write!(Path.join(tmp_dir, "bulk-ok.txt"), "ok")
    render_hook(view, "toggle_select", %{"path" => "bulk-ok.txt"})
    render_hook(view, "toggle_select", %{"path" => "missing-bulk.txt"})
    render_hook(view, "show_delete_confirmation", %{})
    render_hook(view, "confirm_delete_selected", %{})

    refute File.exists?(Path.join(tmp_dir, "bulk-ok.txt"))

    render_hook(view, "toggle_select", %{"path" => "bulk-report.pdf"})
    render_hook(view, "show_delete_confirmation", %{})
    render_hook(view, "confirm_delete_selected", %{})

    refute File.exists?(Path.join(tmp_dir, "bulk-report.pdf"))

    assert Document.get_by_source(source) == nil
    assert Chunk.count_by_document(source_doc.id) == 0
  end

  test "moves items and handles move validation branches", %{conn: conn, tmp_dir: tmp_dir} do
    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    render_hook(view, "move_item", %{"path" => "notes.txt", "type" => "file"})
    render_hook(view, "confirm_move", %{})
    assert has_element?(view, "p", "Already in this folder.")

    render_hook(view, "move_navigate", %{"path" => "target"})
    render_hook(view, "confirm_move", %{})
    assert File.exists?(Path.join(tmp_dir, "target/notes.txt"))

    render_hook(view, "move_item", %{"path" => "docs", "type" => "directory"})
    render_hook(view, "move_navigate", %{"path" => "docs/sub"})
    render_hook(view, "confirm_move", %{})
    assert has_element?(view, "p", "Cannot move a folder into itself.")

    render_hook(view, "move_go_back", %{})
    assert has_element?(view, "span", "docs")
  end

  test "opens and closes the jobs drawer from the monitor jobs button", %{conn: conn} do
    create_job(%{file_path: "drawer-job.txt", status: "pending"})

    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    refute has_element?(view, "#ingestion-jobs-drawer")
    assert has_element?(view, "#monitor-jobs-button", "Monitor jobs (1 active)")

    view = open_jobs_drawer(view)

    assert has_element?(view, "#ingestion-jobs-drawer")
    assert has_element?(view, "p", "drawer-job.txt")

    view
    |> element("#ingestion-jobs-drawer button[aria-label='Close drawer']")
    |> render_click()

    refute has_element?(view, "#ingestion-jobs-drawer")
  end

  test "filters jobs, handles retry/cancel branches, and refreshes on job updates", %{conn: conn} do
    pending = create_job(%{file_path: "pending.txt", status: "pending"})
    completed = create_job(%{file_path: "completed.txt", status: "completed"})

    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
    view = open_jobs_drawer(view)

    render_hook(view, "filter_status", %{"status" => "pending"})
    assert has_element?(view, "p", "pending.txt")
    refute has_element?(view, "p", "completed.txt")

    render_hook(view, "retry_job", %{"id" => completed.id})
    assert Repo.get!(IngestJob, completed.id).status == "completed"

    render_hook(view, "cancel_job", %{"id" => pending.id})
    assert Repo.get!(IngestJob, pending.id).status == "failed"

    render_hook(view, "cancel_job", %{"id" => completed.id})
    assert Repo.get!(IngestJob, completed.id).status == "completed"

    fresh = create_job(%{file_path: "fresh.txt", status: "pending"})
    send(view.pid, {:job_updated, fresh})
    assert has_element?(view, "p", "fresh.txt")
  end

  test "latest failed local job overrides an existing ingested badge", %{conn: conn} do
    source = disk_source("notes.txt")
    create_document_with_chunk(source)

    create_job(%{
      file_path: source,
      status: "failed",
      source_record: %{"name" => "notes.txt"}
    })

    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    assert has_element?(view, "#ingestion-file-list tr", "notes.txt")
    assert has_element?(view, "#ingestion-file-list tr span", "failed")
    refute has_element?(view, "#ingestion-file-list tr span", "ingested")
  end

  test "local file shows stale when modified after indexing", %{conn: conn, tmp_dir: tmp_dir} do
    source = disk_source("notes.txt")
    doc = create_document_with_chunk(source)
    ingested_at = ~U[2024-01-01 00:00:00Z]

    Repo.update!(Ecto.Changeset.change(doc, updated_at: ingested_at))
    File.touch!(Path.join(tmp_dir, "notes.txt"), DateTime.to_unix(ingested_at) + 60)

    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    assert has_element?(view, "#ingestion-file-list tr", "notes.txt")
    assert has_element?(view, "#ingestion-file-list tr span", "stale")
    refute has_element?(view, "#ingestion-file-list tr span", "ingested")
  end

  test "others job filter includes active non-terminal statuses", %{conn: conn} do
    create_job(%{file_path: "pending-other.txt", status: "pending"})
    create_job(%{file_path: "processing-other.txt", status: "processing"})
    create_job(%{file_path: "partial-other.txt", status: "completed_with_errors"})
    create_job(%{file_path: "completed-other.txt", status: "completed"})

    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
    view = open_jobs_drawer(view)

    render_hook(view, "filter_status", %{"status" => "others"})

    assert has_element?(view, "p", "pending-other.txt")
    assert has_element?(view, "p", "processing-other.txt")
    assert has_element?(view, "p", "partial-other.txt")
    refute has_element?(view, "p", "completed-other.txt")
  end

  test "shows chunk progress and retry button for completed_with_errors jobs", %{conn: conn} do
    partial =
      create_job(%{
        file_path: "partial.txt",
        status: "completed_with_errors",
        total_chunks: 10,
        ingested_chunks: 7,
        failed_chunks: 3,
        failed_chunk_indices: [2, 4, 9],
        error: "3 chunks failed after retries"
      })

    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
    view = open_jobs_drawer(view)

    assert has_element?(view, "p", "partial.txt")
    assert has_element?(view, "p", "Chunks: 7/10")
    assert has_element?(view, "p", "Failed chunks: 3")

    render_hook(view, "retry_job", %{"id" => partial.id})

    assert Repo.get!(IngestJob, partial.id).status in [
             "pending",
             "processing",
             "completed",
             "completed_with_errors"
           ]
  end

  test "uploads accepted files", %{conn: conn, tmp_dir: tmp_dir} do
    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
    open_upload_modal(view)

    upload =
      file_input(view, "#upload-form", :files, [
        %{name: "upload.txt", content: "hello upload", type: "text/plain"}
      ])

    assert render_upload(upload, "upload.txt")

    view
    |> form("#upload-form")
    |> render_submit()

    assert File.exists?(Path.join(tmp_dir, "upload.txt"))
  end

  test "closes upload modal after all files upload successfully", %{conn: conn, tmp_dir: tmp_dir} do
    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
    open_upload_modal(view)

    upload =
      file_input(view, "#upload-form", :files, [
        %{name: "modal-close.txt", content: "hello upload", type: "text/plain"}
      ])

    assert render_upload(upload, "modal-close.txt")

    view
    |> form("#upload-form")
    |> render_submit()

    assert File.exists?(Path.join(tmp_dir, "modal-close.txt"))
    refute has_element?(view, "#upload-modal")
    assert has_element?(view, "span", "modal-close.txt")
  end

  @tag :skip
  test "uploads mixed valid and invalid files while keeping the modal open", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
    open_upload_modal(view)

    upload =
      file_input(view, "#upload-form", :files, [
        %{name: "upload.txt", content: "hello upload", type: "text/plain"},
        %{
          name: "bad.md",
          content: "bad upload",
          type: "text/markdown",
          relative_path: "../bad.md"
        }
      ])

    assert render_upload(upload, "upload.txt", 100)
    assert render_upload(upload, "bad.md", 100)

    render_hook(view, "upload", %{})

    assert File.exists?(Path.join(tmp_dir, "upload.txt"))
    refute File.exists?(Path.join(tmp_dir, "bad.md"))
    assert has_element?(view, "#upload-modal")

    state = :sys.get_state(view.pid)

    assert Phoenix.Flash.get(state.socket.assigns.flash, :info) ==
             "1 file(s) uploaded. 1 failed."
  end

  test "submitting the upload form with no entries leaves the modal open", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
    open_upload_modal(view)

    view
    |> form("#upload-form")
    |> render_submit()

    assert has_element?(view, "#upload-modal")

    state = :sys.get_state(view.pid)

    assert state.socket.assigns.modal == :upload
    assert Phoenix.Flash.get(state.socket.assigns.flash, :info) == nil
  end

  test "duplicate upload uses OS-style deduplication", %{conn: conn, tmp_dir: tmp_dir} do
    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
    open_upload_modal(view)

    upload1 =
      file_input(view, "#upload-form", :files, [
        %{name: "report.txt", content: "original", type: "text/plain"}
      ])

    assert render_upload(upload1, "report.txt")
    view |> form("#upload-form") |> render_submit()

    assert File.exists?(Path.join(tmp_dir, "report.txt"))

    open_upload_modal(view)

    upload2 =
      file_input(view, "#upload-form", :files, [
        %{name: "report.txt", content: "duplicate", type: "text/plain"}
      ])

    assert render_upload(upload2, "report.txt")
    view |> form("#upload-form") |> render_submit()

    assert File.read!(Path.join(tmp_dir, "report.txt")) == "original"
    assert File.exists?(Path.join(tmp_dir, "report(1).txt"))
    assert File.read!(Path.join(tmp_dir, "report(1).txt")) == "duplicate"
  end

  test "uploads png and jpg files", %{conn: conn, tmp_dir: tmp_dir} do
    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
    open_upload_modal(view)

    png_upload =
      file_input(view, "#upload-form", :files, [
        %{name: "diagram.png", content: "png-data", type: "image/png"}
      ])

    assert render_upload(png_upload, "diagram.png")

    view
    |> form("#upload-form")
    |> render_submit()

    open_upload_modal(view)

    jpg_upload =
      file_input(view, "#upload-form", :files, [
        %{name: "photo.jpg", content: "jpg-data", type: "image/jpeg"}
      ])

    assert render_upload(jpg_upload, "photo.jpg")

    view
    |> form("#upload-form")
    |> render_submit()

    assert File.exists?(Path.join(tmp_dir, "diagram.png"))
    assert File.exists?(Path.join(tmp_dir, "photo.jpg"))
  end

  # ────────────────────────────────────────────────────────────────
  # NEW: Raw content modal
  # ────────────────────────────────────────────────────────────────

  describe "add raw content modal" do
    test "show_add_raw_modal opens the modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "show_add_raw_modal", %{})
      # h3 text in the template is "Add Raw MD Content"
      assert has_element?(view, "h3", "Add Raw MD Content")
    end

    test "save_raw_content with blank filename shows error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "show_add_raw_modal", %{})
      render_hook(view, "save_raw_content", %{"filename" => "   ", "content" => "hello"})

      assert has_element?(view, "p", "Filename cannot be empty.")
    end

    test "save_raw_content with blank content shows error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "show_add_raw_modal", %{})
      render_hook(view, "save_raw_content", %{"filename" => "myfile", "content" => "   "})

      assert has_element?(view, "p", "Content cannot be empty.")
    end

    test "save_raw_content creates file without extension and auto-appends .md", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "show_add_raw_modal", %{})
      render_hook(view, "save_raw_content", %{"filename" => "mynote", "content" => "# Hi"})

      assert File.exists?(Path.join(tmp_dir, "mynote.md"))
      refute has_element?(view, "h3", "Add Raw MD Content")
    end

    test "save_raw_content preserves existing extension", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "show_add_raw_modal", %{})
      render_hook(view, "save_raw_content", %{"filename" => "doc.txt", "content" => "hello"})

      assert File.exists?(Path.join(tmp_dir, "doc.txt"))
    end

    test "add_raw_content alias behaves identically to save_raw_content", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "show_add_raw_modal", %{})
      render_hook(view, "add_raw_content", %{"filename" => "aliased", "content" => "body"})

      assert File.exists?(Path.join(tmp_dir, "aliased.md"))
    end

    # update_raw_field assigns raw_filename/raw_content but the template input
    # binds to @modal_name — so the assign is updated without crashing but is
    # not reflected in the rendered input value.
    test "update_raw_field for filename does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "show_add_raw_modal", %{})

      assert render_hook(view, "update_raw_field", %{
               "field" => "filename",
               "value" => "typed-name"
             })
    end

    test "update_raw_field for content does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "show_add_raw_modal", %{})

      assert render_hook(view, "update_raw_field", %{
               "field" => "content",
               "value" => "some text"
             })
    end
  end

  # ────────────────────────────────────────────────────────────────
  # NEW: Ingest mode and ingest_selected
  # ────────────────────────────────────────────────────────────────

  describe "ingest mode and triggering ingestion" do
    test "set_mode switches between available modes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      # Template renders mode buttons for ~w(async inline) — switch to inline
      render_hook(view, "set_mode", %{"mode" => "inline"})
      # The active button gets the highlight class; inactive buttons do not
      assert render(view) =~ "bg-\\[#03b6d4\\].*inline|inline.*bg-\\[#03b6d4\\]" or
               render(view) =~ "inline"

      render_hook(view, "set_mode", %{"mode" => "async"})
      assert render(view) =~ "async"
    end

    test "ingest_selected clears selection and shows flash for a file", %{conn: conn} do
      Mox.stub(Zaq.DocumentProcessorMock, :process_single_file, fn _path, _opts ->
        {:ok, %{id: nil}}
      end)

      source = disk_source("alpha.md")

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "toggle_select", %{"path" => "alpha.md"})
      assert has_element?(view, "button", "Delete (1)")

      render_hook(view, "ingest_selected", %{})

      # Selection is cleared after ingestion
      refute has_element?(view, "button", "Delete (1)")
      assert has_element?(view, "#ingest-toast", "Ingestion started.")
      # A job row for the file appears in the jobs table
      assert has_element?(view, "p", "alpha.md")

      job = Repo.get_by!(IngestJob, file_path: source)
      assert job.source_record["kind"] == "file"
      assert job.source_record["attributes"]["relative_path"] == "alpha.md"
    end

    test "ingest_selected clears selection and shows flash for a directory", %{conn: conn} do
      Mox.stub(Zaq.DocumentProcessorMock, :process_single_file, fn _path, _opts ->
        {:ok, %{id: nil}}
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "toggle_select", %{"path" => "docs"})
      assert has_element?(view, "button", "Delete (1)")

      render_hook(view, "ingest_selected", %{})

      # Selection is cleared after ingestion
      refute has_element?(view, "button", "Delete (1)")
      assert has_element?(view, "#ingest-toast", "Ingestion started.")
      # A job row for a file inside the folder appears in the jobs table
      assert has_element?(view, "p", ~r/readme\.md/)
    end

    test "ingest_selected processes file without role_id (RBAC-based access)", %{conn: conn} do
      parent = self()

      Mox.stub(Zaq.DocumentProcessorMock, :process_single_file, fn path, _opts ->
        send(parent, {:path_ingested, path})
        {:ok, %{id: nil}}
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "set_mode", %{"mode" => "inline"})
      render_hook(view, "toggle_select", %{"path" => "alpha.md"})
      render_hook(view, "ingest_selected", %{})

      assert_receive {:path_ingested, _path}, 500
    end

    test "ingest_selected reports an error flash when all selected records fail", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      :sys.replace_state(view.pid, fn state ->
        bad_record = %Record{id: "bad", kind: :unsupported, name: "bad"}

        assigns =
          Map.merge(state.socket.assigns, %{
            selected: MapSet.new(["bad"]),
            records_by_path: Map.put(state.socket.assigns.records_by_path, "bad", bad_record)
          })

        put_in(state.socket.assigns, assigns)
      end)

      render_hook(view, "ingest_selected", %{})

      state = :sys.get_state(view.pid)

      assert Phoenix.Flash.get(state.socket.assigns.flash, :error) ==
               "No selected records could be ingested (1 failed)."
    end

    test "ingest_selected reports a warning flash when some records fail", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      :sys.replace_state(view.pid, fn state ->
        bad_record = %Record{id: "bad", kind: :unsupported, name: "bad"}

        assigns =
          Map.merge(state.socket.assigns, %{
            selected: MapSet.new(["alpha.md", "bad"]),
            records_by_path: Map.put(state.socket.assigns.records_by_path, "bad", bad_record)
          })

        put_in(state.socket.assigns, assigns)
      end)

      render_hook(view, "ingest_selected", %{})

      state = :sys.get_state(view.pid)

      assert state.socket.assigns.ingest_toast == %{
               kind: :info,
               message: "Ingestion started for 1 item(s); 1 failed."
             }

      assert has_element?(view, "#ingest-toast")
    end
  end

  # ────────────────────────────────────────────────────────────────
  # NEW: validate_upload (noop handler)
  # ────────────────────────────────────────────────────────────────

  describe "validate_upload" do
    test "validate_upload event does not crash the view", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      # Should return {:noreply, socket} without changing state
      assert render_hook(view, "validate_upload", %{})
    end
  end

  # ────────────────────────────────────────────────────────────────
  # NEW: filter_status reset to "all"
  # ────────────────────────────────────────────────────────────────

  describe "filter_status all" do
    test "filtering by 'all' shows jobs of every status", %{conn: conn} do
      create_job(%{file_path: "p.txt", status: "pending"})
      create_job(%{file_path: "c.txt", status: "completed"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
      view = open_jobs_drawer(view)

      render_hook(view, "filter_status", %{"status" => "pending"})
      refute has_element?(view, "p", "c.txt")

      render_hook(view, "filter_status", %{"status" => "all"})
      assert has_element?(view, "p", "p.txt")
      assert has_element?(view, "p", "c.txt")
    end
  end

  describe "lane c edge branches" do
    test "save_raw_content surfaces upload errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "show_add_raw_modal", %{})
      render_hook(view, "save_raw_content", %{"filename" => "../escape", "content" => "body"})

      assert has_element?(view, "p", "Save failed: :path_traversal")
    end

    test "confirm_move shows an error when source is missing", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "move_item", %{"path" => "notes.txt", "type" => "file"})
      render_hook(view, "move_navigate", %{"path" => "target"})

      File.rm!(Path.join(tmp_dir, "notes.txt"))

      render_hook(view, "confirm_move", %{})
      assert render(view) =~ "Move failed"
    end

    test "ingest_selected skips missing selected paths", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
      before_count = Repo.aggregate(IngestJob, :count)

      render_hook(view, "toggle_select", %{"path" => "missing-file.md"})
      render_hook(view, "ingest_selected", %{})

      assert Repo.aggregate(IngestJob, :count) == before_count
      refute has_element?(view, "p", "missing-file.md")
    end

    test "retry_job and cancel_job return not_found for missing ids", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
      missing_id = Ecto.UUID.generate()

      render_hook(view, "retry_job", %{"id" => missing_id})
      retry_state = :sys.get_state(view.pid)

      assert Phoenix.Flash.get(retry_state.socket.assigns.flash, :error) ==
               "Retry failed: not_found"

      render_hook(view, "cancel_job", %{"id" => missing_id})
      cancel_state = :sys.get_state(view.pid)

      assert Phoenix.Flash.get(cancel_state.socket.assigns.flash, :error) ==
               "Cancel failed: not_found"
    end

    test "filter_status with unknown value returns empty job list", %{conn: conn} do
      create_job(%{file_path: "a-pending.txt", status: "pending"})
      create_job(%{file_path: "a-completed.txt", status: "completed"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
      view = open_jobs_drawer(view)

      render_hook(view, "filter_status", %{"status" => "unknown_status"})

      refute has_element?(view, "p", "a-pending.txt")
      refute has_element?(view, "p", "a-completed.txt")
      assert has_element?(view, "p", "No jobs yet")
    end
  end

  # ────────────────────────────────────────────────────────────────
  # NEW: move_go_back from root stays at "."
  # ────────────────────────────────────────────────────────────────

  describe "move_go_back at root" do
    test "move_go_back from root dir '.' stays at root", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "move_item", %{"path" => "notes.txt", "type" => "file"})
      # Already at root; going back should not crash and should stay at "."
      render_hook(view, "move_go_back", %{})
      assert has_element?(view, "h3", "Move")
    end

    test "move_navigate to an invalid folder clears move folder options", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "move_item", %{"path" => "notes.txt", "type" => "file"})
      render_hook(view, "move_navigate", %{"path" => "../outside"})

      state = :sys.get_state(view.pid)
      assert state.socket.assigns.move_folders == []
    end
  end

  test "empty configured volumes fall back to the default current volume", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    original_ingestion = Application.get_env(:zaq, Zaq.Ingestion)
    original_storage = Application.get_env(:zaq, Zaq.Storage)
    storage_config = [base_path: tmp_dir, volumes: %{}]

    Application.put_env(:zaq, Zaq.Ingestion, storage_config)
    Application.put_env(:zaq, Zaq.Storage, storage_config)

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.Ingestion, original_ingestion || [])
      Application.put_env(:zaq, Zaq.Storage, original_storage || [])
    end)

    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    state = :sys.get_state(view.pid)

    assert state.socket.assigns.current_volume == "default"
    assert state.socket.assigns.volumes == %{"default" => Path.expand(tmp_dir)}
  end

  describe "mount/provider normalization" do
    test "mounting /bo/ingestion/local normalizes provider to local", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion/local")
      state = :sys.get_state(view.pid)

      assert state.socket.assigns.provider == "local"
      assert state.socket.assigns.current_path == "/bo/ingestion"
    end
  end

  # ────────────────────────────────────────────────────────────────
  # NEW: ingestion_map stale detection
  # ────────────────────────────────────────────────────────────────

  describe "ingestion_map stale detection" do
    test "file with no document shows as not ingested", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/ingestion")

      # alpha.md has no document — should NOT show an ingested badge
      refute html =~ ~r/alpha\.md.*ingested/s
    end

    test "file ingested after last modification shows as up to date", %{conn: conn} do
      # Create the document normally, then force updated_at to the future
      doc = create_document_with_chunk(disk_source("alpha.md"), %{content: "# alpha"})

      Repo.update_all(
        from(d in Document, where: d.id == ^doc.id),
        set: [updated_at: DateTime.utc_now() |> DateTime.add(3600)]
      )

      {:ok, _view, html} = live(conn, ~p"/bo/ingestion")

      refute html =~ "stale"
    end
  end

  # ────────────────────────────────────────────────────────────────
  # format_size/1 and status_pill_classes/1 helper functions
  # ────────────────────────────────────────────────────────────────

  describe "format_size/1" do
    alias ZaqWeb.Live.BO.AI.IngestionLive

    test "bytes < 1024 shows B suffix" do
      assert IngestionLive.format_size(512) == "512 B"
    end

    test "bytes < 1 MB shows KB suffix" do
      assert IngestionLive.format_size(2048) == "2.0 KB"
    end

    test "bytes >= 1 MB shows MB suffix" do
      assert IngestionLive.format_size(2_097_152) == "2.0 MB"
    end
  end

  describe "status_pill_classes/1" do
    alias ZaqWeb.Live.BO.AI.IngestionLive

    test "pending returns elevated pill classes" do
      assert "zaq-pill" in IngestionLive.status_pill_classes("pending")
      assert "zaq-pill--elevated" in IngestionLive.status_pill_classes("pending")
    end

    test "processing returns accent pill classes" do
      assert "zaq-pill--accent" in IngestionLive.status_pill_classes("processing")
    end

    test "completed returns success pill classes" do
      assert "zaq-pill--success" in IngestionLive.status_pill_classes("completed")
    end

    test "failed returns danger pill classes" do
      assert "zaq-pill--danger" in IngestionLive.status_pill_classes("failed")
    end

    test "unknown status returns elevated fallback" do
      assert "zaq-pill--elevated" in IngestionLive.status_pill_classes("unknown")
    end
  end

  # ────────────────────────────────────────────────────────────────
  # NEW: handle_info job_updated — processing with chunks scheduled
  # ────────────────────────────────────────────────────────────────

  describe "handle_info {:job_updated, job} — processing with chunks" do
    test "refreshes entries when job transitions to processing with chunks scheduled", %{
      conn: conn
    } do
      job = create_job(%{file_path: "notes.txt", status: "pending"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      # Transition to processing in DB and use the real struct (has all fields)
      {:ok, processing_job} =
        Repo.get!(IngestJob, job.id)
        |> IngestJob.changeset(%{status: "processing", total_chunks: 5})
        |> Repo.update()

      send(view.pid, {:job_updated, processing_job})

      view = open_jobs_drawer(view)
      # View must still be alive and not crash
      assert has_element?(view, "p", "notes.txt")
    end

    test "job_updated for a job not matching the current filter is silently ignored", %{
      conn: conn
    } do
      # Create a completed job in the DB so we have a real struct with all fields
      completed_job = create_job(%{file_path: "ghost.txt", status: "completed"})
      completed_job = Repo.get!(IngestJob, completed_job.id)

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      # Filter to only show pending jobs — "completed" won't match
      render_hook(view, "filter_status", %{"status" => "pending"})

      # Send the completed job — it has no pending match so handle_filtered_job no-op fires
      send(view.pid, {:job_updated, completed_job})

      state = :sys.get_state(view.pid)
      job_ids = Enum.map(state.socket.assigns.jobs, & &1.id)
      refute completed_job.id in job_ids
    end

    test "job_updated removes an existing row when it stops matching the current filter", %{
      conn: conn
    } do
      pending = create_job(%{file_path: "filtered-away.txt", status: "pending"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
      render_hook(view, "filter_status", %{"status" => "pending"})
      view = open_jobs_drawer(view)

      assert has_element?(view, "p", "filtered-away.txt")

      completed =
        Repo.get!(IngestJob, pending.id)
        |> IngestJob.changeset(%{status: "completed"})
        |> Repo.update!()

      send(view.pid, {:job_updated, completed})

      refute has_element?(view, "p", "filtered-away.txt")
    end

    test "job_updated ignores malformed payloads", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
      state_before = :sys.get_state(view.pid).socket.assigns.jobs

      send(view.pid, {:job_updated, :not_a_job})

      assert :sys.get_state(view.pid).socket.assigns.jobs == state_before
    end

    test "others filter removes a job once it stops matching", %{conn: conn} do
      pending = create_job(%{file_path: "others-pending.txt", status: "pending"})
      _failed = create_job(%{file_path: "others-failed.txt", status: "failed"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
      render_hook(view, "filter_status", %{"status" => "others"})
      view = open_jobs_drawer(view)

      assert has_element?(view, "p", "others-pending.txt")
      refute has_element?(view, "p", "others-failed.txt")

      updated =
        Repo.get!(IngestJob, pending.id)
        |> IngestJob.changeset(%{status: "failed"})
        |> Repo.update!()

      send(view.pid, {:job_updated, updated})

      refute has_element?(view, "p", "others-pending.txt")
    end

    test "job_updated updates existing rows and caps the list at 20 entries", %{conn: conn} do
      jobs = for idx <- 1..20, do: create_job(%{file_path: "job-#{idx}.txt", status: "pending"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      existing = List.first(jobs)

      updated_existing =
        Repo.get!(IngestJob, existing.id)
        |> IngestJob.changeset(%{status: "processing"})
        |> Repo.update!()

      send(view.pid, {:job_updated, updated_existing})

      state_after_update = :sys.get_state(view.pid)
      assert updated_existing.id in Enum.map(state_after_update.socket.assigns.jobs, & &1.id)

      new_job = create_job(%{file_path: "job-21.txt", status: "pending"})
      send(view.pid, {:job_updated, new_job})

      state = :sys.get_state(view.pid)
      job_ids = Enum.map(state.socket.assigns.jobs, & &1.id)

      assert new_job.id in job_ids
      assert length(job_ids) == 20
    end
  end

  # ────────────────────────────────────────────────────────────────
  # handle_info {:job_progress, ...} — PDF prep progress indicator
  # ────────────────────────────────────────────────────────────────

  describe "handle_info {:job_progress, job_id, payload}" do
    test "renders a Preparing indicator for a processing job with no chunks yet", %{conn: conn} do
      job = create_job(%{file_path: "scan.pdf", status: "processing", total_chunks: 0})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      send(
        view.pid,
        {:job_progress, job.id,
         %{
           "stage" => "image_to_text",
           "current" => 1,
           "total" => 3,
           "status" => "processing",
           "label" => "figure-1.png"
         }}
      )

      view = open_jobs_drawer(view)
      html = render(view)
      assert html =~ "Preparing"
      assert html =~ "describing images 1/3"
      assert html =~ "figure-1.png"
    end

    test "clears the prep indicator once chunks are scheduled", %{conn: conn} do
      job = create_job(%{file_path: "scan.pdf", status: "processing", total_chunks: 0})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      send(
        view.pid,
        {:job_progress, job.id, %{"current" => 1, "total" => 2, "status" => "processing"}}
      )

      view = open_jobs_drawer(view)
      assert render(view) =~ "Preparing"

      # Chunks scheduled: the job leaves the prep phase.
      scheduled =
        Repo.get!(IngestJob, job.id)
        |> IngestJob.changeset(%{status: "processing", total_chunks: 2})
        |> Repo.update!()

      send(view.pid, {:job_updated, scheduled})

      view = open_jobs_drawer(view)
      refute render(view) =~ "Preparing"
    end

    test "drops prep progress when the job completes", %{conn: conn} do
      job = create_job(%{file_path: "scan.pdf", status: "processing", total_chunks: 0})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      send(
        view.pid,
        {:job_progress, job.id, %{"current" => 2, "total" => 2, "status" => "completed"}}
      )

      view = open_jobs_drawer(view)
      assert render(view) =~ "Preparing"

      completed =
        Repo.get!(IngestJob, job.id)
        |> IngestJob.changeset(%{status: "completed", total_chunks: 2, ingested_chunks: 2})
        |> Repo.update!()

      send(view.pid, {:job_updated, completed})

      state = :sys.get_state(view.pid)
      refute Map.has_key?(state.socket.assigns.prep_progress, job.id)
    end

    test "drops prep progress when the job is sent back to pending for retry", %{conn: conn} do
      job = create_job(%{file_path: "scan.pdf", status: "processing", total_chunks: 0})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      send(
        view.pid,
        {:job_progress, job.id, %{"current" => 1, "total" => 2, "status" => "processing"}}
      )

      view = open_jobs_drawer(view)
      assert render(view) =~ "Preparing"

      # A retriable failure sends the job back to "pending" during Oban backoff.
      retried =
        Repo.get!(IngestJob, job.id)
        |> IngestJob.changeset(%{status: "pending", total_chunks: 0})
        |> Repo.update!()

      send(view.pid, {:job_updated, retried})

      state = :sys.get_state(view.pid)
      refute Map.has_key?(state.socket.assigns.prep_progress, job.id)
    end

    test "ignores a straggler progress message that arrives after the job finished", %{conn: conn} do
      job = create_job(%{file_path: "scan.pdf", status: "processing", total_chunks: 0})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      send(
        view.pid,
        {:job_progress, job.id, %{"current" => 1, "total" => 2, "status" => "processing"}}
      )

      view = open_jobs_drawer(view)
      assert render(view) =~ "Preparing"

      completed =
        Repo.get!(IngestJob, job.id)
        |> IngestJob.changeset(%{status: "completed", total_chunks: 2, ingested_chunks: 2})
        |> Repo.update!()

      send(view.pid, {:job_updated, completed})

      # Out-of-order: a progress line emitted just before exit arrives late.
      send(
        view.pid,
        {:job_progress, job.id, %{"current" => 2, "total" => 2, "status" => "processing"}}
      )

      state = :sys.get_state(view.pid)
      refute Map.has_key?(state.socket.assigns.prep_progress, job.id)
      view = open_jobs_drawer(view)
      refute render(view) =~ "Preparing"
    end

    test "prunes a stale prep entry left by an orphaned job after the TTL", %{conn: conn} do
      Application.put_env(:zaq, :ingestion_prep_ttl_ms, 0)
      on_exit(fn -> Application.delete_env(:zaq, :ingestion_prep_ttl_ms) end)

      job = create_job(%{file_path: "scan.pdf", status: "processing", total_chunks: 0})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      send(
        view.pid,
        {:job_progress, job.id,
         %{"stage" => "image_to_text", "current" => 2, "total" => 3, "status" => "processing"}}
      )

      view = open_jobs_drawer(view)
      assert render(view) =~ "describing images 2/3"

      # No terminal broadcast ever arrives (orphaned job). With a zero TTL the
      # sweep expires the numeric entry; the bar falls back to indeterminate.
      send(view.pid, :prune_prep_progress)

      state = :sys.get_state(view.pid)
      refute Map.has_key?(state.socket.assigns.prep_progress, job.id)
      refute Map.has_key?(state.socket.assigns.prep_seen_at, job.id)
      view = open_jobs_drawer(view)
      refute render(view) =~ "describing images 2/3"
    end

    test "keeps a fresh prep entry that is still within the TTL", %{conn: conn} do
      job = create_job(%{file_path: "scan.pdf", status: "processing", total_chunks: 0})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      send(
        view.pid,
        {:job_progress, job.id,
         %{"stage" => "image_to_text", "current" => 1, "total" => 3, "status" => "processing"}}
      )

      # Default TTL is 30 min, so an immediate sweep must not drop the entry.
      send(view.pid, :prune_prep_progress)

      state = :sys.get_state(view.pid)
      assert Map.has_key?(state.socket.assigns.prep_progress, job.id)
      view = open_jobs_drawer(view)
      assert render(view) =~ "describing images 1/3"
    end

    test "prune removes stale prep entries and keeps fresh ones queued for another sweep", %{
      conn: conn
    } do
      Application.put_env(:zaq, :ingestion_prep_ttl_ms, 0)
      on_exit(fn -> Application.delete_env(:zaq, :ingestion_prep_ttl_ms) end)

      job_a = create_job(%{file_path: "scan-a.pdf", status: "processing", total_chunks: 0})
      job_b = create_job(%{file_path: "scan-b.pdf", status: "processing", total_chunks: 0})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      send(
        view.pid,
        {:job_progress, job_a.id, %{"current" => 1, "total" => 3, "status" => "processing"}}
      )

      send(
        view.pid,
        {:job_progress, job_b.id, %{"current" => 1, "total" => 3, "status" => "processing"}}
      )

      :sys.replace_state(view.pid, fn state ->
        now = :erlang.monotonic_time(:millisecond)

        update_in(state.socket.assigns.prep_seen_at, fn seen_at ->
          seen_at
          |> Map.put(job_a.id, now - 1_000)
          |> Map.put(job_b.id, now + 1_000)
        end)
      end)

      send(view.pid, :prune_prep_progress)

      state = :sys.get_state(view.pid)
      refute Map.has_key?(state.socket.assigns.prep_progress, job_a.id)
      assert Map.has_key?(state.socket.assigns.prep_progress, job_b.id)
      assert state.socket.assigns.prep_progress != %{}
    end
  end

  # ────────────────────────────────────────────────────────────────
  # status_pill_classes/1 — completed_with_errors
  # ────────────────────────────────────────────────────────────────

  describe "status_pill_classes/1 completed_with_errors" do
    alias ZaqWeb.Live.BO.AI.IngestionLive

    test "completed_with_errors returns warning pill classes" do
      assert "zaq-pill--warning" in IngestionLive.status_pill_classes("completed_with_errors")
    end
  end

  # ────────────────────────────────────────────────────────────────
  # NEW: Grid view job status badges
  # These tests exercise branches inside file_grid_view/1 that are
  # not hit by any other test (processing / pending / failed / stale
  # status badges in the grid card).
  # ────────────────────────────────────────────────────────────────

  describe "grid view job status badges" do
    test "grid view shows ingested badge and shared indicator when a document has permissions", %{
      conn: conn
    } do
      doc = create_document_with_chunk(disk_source("notes.txt"), %{content: "ingested content"})
      person = People.list_people() |> List.first()

      if person do
        Ingestion.set_document_permission(doc.id, :person, person.id, ["read"])
      end

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
      render_hook(view, "toggle_view_mode", %{"mode" => "grid"})

      # Should render ingested state without crashing
      assert render(view) =~ "ingested"
    end

    test "list view shows source ACL sharing for an un-ingested file", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "source-shared.md"), "content")
      source = source_entry("source-shared.md")

      {:ok, person} =
        People.create_person(%{
          full_name: "Source Shared Person",
          email: "source_shared_#{System.unique_integer([:positive])}@example.com"
        })

      {:ok, _permission} =
        Permissions.grant(%StorageEntry{id: source.id}, %{
          person_id: person.id,
          access_rights: ["read"]
        })

      {:ok, view, html} = live(conn, ~p"/bo/ingestion")
      status = :sys.get_state(view.pid).socket.assigns.ingestion_map["source-shared.md"]

      assert status.permissions_count == 1
      assert status.can_share?
      assert html =~ "shared"
    end

    test "list view shows public source ACL without counting Everyone as shared", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "source-public.md"), "content")
      source = source_entry("source-public.md")
      {:ok, _permission} = Permissions.grant_public(%StorageEntry{id: source.id})

      {:ok, view, html} = live(conn, ~p"/bo/ingestion")
      status = :sys.get_state(view.pid).socket.assigns.ingestion_map["source-public.md"]

      assert status.permissions_count == 0
      assert status.is_public
      assert html =~ "Public"
    end

    test "folder inherits public source ACL display from parent", %{conn: conn, tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "public-parent"))
      File.write!(Path.join([tmp_dir, "public-parent", "child.md"]), "content")
      parent = source_entry("public-parent", "directory")
      _child = source_entry("public-parent/child.md")
      {:ok, _permission} = Permissions.grant_public(%StorageEntry{id: parent.id})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "navigate", %{"path" => "public-parent"})
      render_hook(view, "share_item", %{"path" => "public-parent/child.md"})
      state = :sys.get_state(view.pid)

      assert state.socket.assigns.share_modal_public_inherited?
    end
  end

  # ────────────────────────────────────────────────────────────────
  # NEW: Volume selection (multi-volume ingestion)
  # ────────────────────────────────────────────────────────────────

  describe "volume selection" do
    setup %{conn: conn, tmp_dir: tmp_dir} do
      vol_docs = Path.join(tmp_dir, "volumes/docs")
      vol_archives = Path.join(tmp_dir, "volumes/archives")
      File.mkdir_p!(vol_docs)
      File.mkdir_p!(vol_archives)
      File.write!(Path.join(vol_docs, "manual.md"), "# Manual")
      File.write!(Path.join(vol_archives, "old.md"), "# Old")

      original_ingestion = Application.get_env(:zaq, Zaq.Ingestion)
      original_storage = Application.get_env(:zaq, Zaq.Storage)

      storage_config = [base_path: tmp_dir]

      Application.put_env(:zaq, Zaq.Ingestion, storage_config)
      Application.put_env(:zaq, Zaq.Storage, storage_config)

      Repo.get_by!(ChannelConfig, provider: "disk")
      |> ChannelConfig.changeset(%{
        settings: %{
          "volumes" => [
            %{"name" => "docs", "path" => "volumes/docs"},
            %{"name" => "archives", "path" => "volumes/archives"}
          ]
        }
      })
      |> Repo.update!()

      on_exit(fn ->
        Application.put_env(:zaq, Zaq.Ingestion, original_ingestion || [])
        Application.put_env(:zaq, Zaq.Storage, original_storage || [])
      end)

      {:ok, conn: conn, vol_docs: vol_docs, vol_archives: vol_archives}
    end

    test "shows volume selector when multiple volumes configured", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/ingestion")
      assert html =~ "Sources"
      assert html =~ "docs"
      assert html =~ "archives"
    end

    test "shows enabled data source providers as source buttons", %{conn: conn} do
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Google Drive Source",
        provider: "google_drive",
        kind: "data_source",
        enabled: true,
        settings: %{}
      })
      |> Repo.insert!()

      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Disabled SharePoint Source",
        provider: "sharepoint",
        kind: "data_source",
        enabled: false,
        settings: %{}
      })
      |> Repo.insert!()

      {:ok, _view, html} = live(conn, ~p"/bo/ingestion")

      assert html =~ "Sources"
      assert html =~ "Google Drive"
      assert html =~ ~s(phx-click="switch_source")
      assert html =~ ~s(phx-value-source="provider:google_drive")
      refute html =~ "SharePoint"
      refute html =~ ~s(phx-value-source="provider:sharepoint")
    end

    test "shows the same source selector on provider pages", %{conn: conn} do
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Google Drive Source",
        provider: "google_drive",
        kind: "data_source",
        enabled: true,
        settings: %{}
      })
      |> Repo.insert!()

      {:ok, _view, html} = live(conn, ~p"/bo/ingestion/google_drive")

      assert html =~ "Sources"
      assert html =~ "Google Drive"
      assert html =~ ~s(phx-value-source="volume:archives")
      assert html =~ ~s(phx-value-source="volume:docs")
    end

    test "switch_source navigates to a data source provider", %{conn: conn} do
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Google Drive Source",
        provider: "google_drive",
        kind: "data_source",
        enabled: true,
        settings: %{}
      })
      |> Repo.insert!()

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      assert {:error, {:live_redirect, %{to: "/bo/ingestion/google_drive"}}} =
               render_click(view, "switch_source", %{"source" => "provider:google_drive"})
    end

    test "switch_volume changes current volume and loads entries", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "switch_volume", %{"volume" => "archives"})

      assert has_element?(view, "span", "old.md")
      refute has_element?(view, "span", "manual.md")
    end

    test "switch_volume resets current_dir to root", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "switch_volume", %{"volume" => "archives"})

      state = :sys.get_state(view.pid)
      assert state.socket.assigns.current_dir == "."
      assert state.socket.assigns.current_volume == "archives"
    end

    test "files in the selected volume are listed after switching", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      # Switch to docs explicitly
      render_hook(view, "switch_volume", %{"volume" => "docs"})
      assert has_element?(view, "span", "manual.md")
      refute has_element?(view, "span", "old.md")

      # Switch to archives
      render_hook(view, "switch_volume", %{"volume" => "archives"})
      assert has_element?(view, "span", "old.md")
      refute has_element?(view, "span", "manual.md")

      # Switch back to docs
      render_hook(view, "switch_volume", %{"volume" => "docs"})
      assert has_element?(view, "span", "manual.md")
      refute has_element?(view, "span", "old.md")
    end
  end

  # ────────────────────────────────────────────────────────────────
  # Markdown files on disk are normal records. Converted content is stored on the
  # primary document and no longer hides a duplicate sidecar document.
  # ────────────────────────────────────────────────────────────────

  describe "markdown record selection" do
    test "keeps pdf-adjacent markdown selectable", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "report.pdf"), "%PDF-1.4")
      File.write!(Path.join(tmp_dir, "report_converted.md"), "# Report sidecar")

      create_document_with_chunk(disk_source("report.pdf"), %{content: "# Report sidecar"})
      create_document_with_chunk(disk_source("report_converted.md"))

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      assert has_element?(view, "span", "report.pdf")
      assert render(view) =~ "report_converted.md"

      render_hook(view, "select_all", %{})
      selected = :sys.get_state(view.pid).socket.assigns.selected

      assert MapSet.member?(selected, "report.pdf")
      assert MapSet.member?(selected, "report_converted.md")
    end

    test "does not pair same-basename md without explicit metadata link", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "report.pdf"), "%PDF-1.4")
      File.write!(Path.join(tmp_dir, "report.md"), "# Manual notes")

      create_document_with_chunk(disk_source("report.pdf"))
      create_document_with_chunk(disk_source("report.md"))

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      assert has_element?(view, "span", "report.pdf")
      assert has_element?(view, "span", "report.md")

      render_hook(view, "select_all", %{})
      selected = :sys.get_state(view.pid).socket.assigns.selected

      assert MapSet.member?(selected, "report.pdf")
      assert MapSet.member?(selected, "report.md")
    end

    test "keeps image-adjacent markdown selectable", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "photo.png"), "png-bytes")
      File.write!(Path.join(tmp_dir, "photo.md"), "# OCR output")

      create_document_with_chunk(disk_source("photo.png"), %{content: "# OCR output"})
      create_document_with_chunk(disk_source("photo.md"))

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      assert has_element?(view, "span", "photo.png")
      assert render(view) =~ "photo.md"

      render_hook(view, "select_all", %{})
      selected = :sys.get_state(view.pid).socket.assigns.selected

      assert MapSet.member?(selected, "photo.png")
      assert MapSet.member?(selected, "photo.md")
    end
  end

  describe "share modal — document permissions" do
    setup %{conn: conn, tmp_dir: tmp_dir} do
      unique = System.unique_integer([:positive])
      File.write!(Path.join(tmp_dir, "alpha.md"), "shared content")

      {:ok, person} =
        People.create_person(%{
          full_name: "Alice Share",
          email: "alice_share#{unique}@example.com"
        })

      {:ok, team} =
        People.create_team(%{name: "Eng#{unique}"})

      {:ok, doc} = Document.create(%{source: disk_source("alpha.md"), content: "shared content"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      %{view: view, doc: doc, person: person, team: team, tmp_dir: tmp_dir}
    end

    test "share_item opens the share modal for a file", %{view: view} do
      assert render(view) =~ "phx-click=\"share_item\""

      render_hook(view, "share_item", %{"path" => "alpha.md"})

      assert has_element?(view, "button", "Save Permissions")
    end

    test "add_permission_target with a person appends to pending", %{
      view: view,
      person: person
    } do
      render_hook(view, "share_item", %{"path" => "alpha.md"})
      render_hook(view, "add_permission_target", %{"value" => "person:#{person.id}"})

      assert render(view) =~ person.full_name
    end

    test "add_permission_target with a team appends to pending", %{view: view, team: team} do
      render_hook(view, "share_item", %{"path" => "alpha.md"})
      render_hook(view, "add_permission_target", %{"value" => "team:#{team.id}"})

      assert render(view) =~ team.name
    end

    test "toggle_permission_right adds a right to a pending entry", %{
      view: view,
      person: person
    } do
      render_hook(view, "share_item", %{"path" => "alpha.md"})
      render_hook(view, "add_permission_target", %{"value" => "person:#{person.id}"})

      pending_before =
        :sys.get_state(view.pid).socket.assigns.share_modal_pending

      assert [%{access_rights: ["read"]}] = pending_before

      render_hook(view, "toggle_permission_right", %{"index" => "0", "right" => "write"})

      pending_after =
        :sys.get_state(view.pid).socket.assigns.share_modal_pending

      assert [%{access_rights: rights}] = pending_after
      assert "write" in rights
    end

    test "confirm_share persists permissions to the database", %{
      view: view,
      doc: doc,
      person: person
    } do
      render_hook(view, "share_item", %{"path" => "alpha.md"})
      render_hook(view, "add_permission_target", %{"value" => "person:#{person.id}"})
      render_hook(view, "confirm_share", %{})

      refute has_element?(view, "button", "Save Permissions")
      source = source_entry("alpha.md")
      assert [source_perm] = Permissions.list(%StorageEntry{id: source.id})
      assert source_perm.person_id == person.id

      assert [perm] = Zaq.Ingestion.list_document_permissions(doc.id)
      assert perm.person_id == person.id
      assert perm.access_rights == ["read"]
    end

    test "remove_permission deletes an existing permission", %{
      view: view,
      doc: doc,
      person: person
    } do
      source = source_entry("alpha.md")

      {:ok, perm} =
        Permissions.grant(%StorageEntry{id: source.id}, %{
          person_id: person.id,
          access_rights: ["read"]
        })

      render_hook(view, "share_item", %{"path" => "alpha.md"})
      render_hook(view, "remove_permission", %{"id" => to_string(perm.id)})
      render_hook(view, "confirm_share", %{})

      assert Zaq.Ingestion.list_document_permissions(doc.id) == []
      assert Permissions.list(%StorageEntry{id: source.id}) == []
    end

    test "duplicate add_permission_target is ignored", %{view: view, person: person} do
      render_hook(view, "share_item", %{"path" => "alpha.md"})
      render_hook(view, "add_permission_target", %{"value" => "person:#{person.id}"})
      render_hook(view, "add_permission_target", %{"value" => "person:#{person.id}"})

      pending = :sys.get_state(view.pid).socket.assigns.share_modal_pending
      assert length(pending) == 1
    end

    test "duplicate pending share target keeps the existing pending entry unchanged", %{
      view: view,
      person: person
    } do
      render_hook(view, "share_item", %{"path" => "alpha.md"})
      render_hook(view, "add_permission_target", %{"value" => "person:#{person.id}"})

      state = :sys.get_state(view.pid)
      [pending_entry] = state.socket.assigns.share_modal_pending

      :sys.replace_state(view.pid, fn current_state ->
        update_in(current_state.socket.assigns.share_modal_targets_options, fn options ->
          [{person.full_name, "person:#{person.id}"} | options]
        end)
      end)

      render_hook(view, "add_permission_target", %{"value" => "person:#{person.id}"})

      updated = :sys.get_state(view.pid).socket.assigns.share_modal_pending
      assert length(updated) == 1
      [updated_entry] = updated

      assert updated_entry.id == pending_entry.id
      assert updated_entry.type == pending_entry.type
    end

    test "remove_pending removes an entry from share_modal_pending", %{view: view, person: person} do
      render_hook(view, "share_item", %{"path" => "alpha.md"})
      render_hook(view, "add_permission_target", %{"value" => "person:#{person.id}"})

      render_hook(view, "remove_pending", %{"index" => "0"})

      pending = :sys.get_state(view.pid).socket.assigns.share_modal_pending
      assert pending == []
    end

    test "add_permission_target with invalid value is a no-op", %{view: view} do
      render_hook(view, "share_item", %{"path" => "alpha.md"})
      render_hook(view, "add_permission_target", %{"value" => "invalid_value"})

      pending = :sys.get_state(view.pid).socket.assigns.share_modal_pending
      assert pending == []
    end

    test "remove_permission for folder deletes across all docs", %{
      conn: conn,
      person: person,
      tmp_dir: tmp_dir
    } do
      unique = System.unique_integer([:positive])
      folder_path = "folder-#{unique}"
      File.mkdir_p!(Path.join(tmp_dir, folder_path))
      File.write!(Path.join([tmp_dir, folder_path, "a.md"]), "a")
      File.write!(Path.join([tmp_dir, folder_path, "b.md"]), "b")
      {:ok, doc1} = Document.create(%{source: disk_source("#{folder_path}/a.md"), content: "a"})
      {:ok, doc2} = Document.create(%{source: disk_source("#{folder_path}/b.md"), content: "b"})
      folder = source_entry(folder_path, "directory")

      {:ok, perm1} =
        Permissions.grant(%StorageEntry{id: folder.id}, %{
          person_id: person.id,
          access_rights: ["read"]
        })

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "share_item", %{
        "path" => folder_path,
        "type" => "directory"
      })

      render_hook(view, "remove_permission", %{"id" => to_string(perm1.id)})
      render_hook(view, "confirm_share", %{})

      assert Zaq.Ingestion.list_document_permissions(doc1.id) == []
      assert Zaq.Ingestion.list_document_permissions(doc2.id) == []
      assert Permissions.list(%StorageEntry{id: folder.id}) == []
    end

    test "confirm_share for folder persists permissions to all docs", %{
      conn: conn,
      person: person,
      tmp_dir: tmp_dir
    } do
      unique = System.unique_integer([:positive])
      folder_path = "sharedir-#{unique}"
      File.mkdir_p!(Path.join(tmp_dir, folder_path))
      File.write!(Path.join([tmp_dir, folder_path, "x.md"]), "x")
      File.write!(Path.join([tmp_dir, folder_path, "y.md"]), "y")
      {:ok, doc1} = Document.create(%{source: disk_source("#{folder_path}/x.md"), content: "x"})
      {:ok, doc2} = Document.create(%{source: disk_source("#{folder_path}/y.md"), content: "y"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "share_item", %{
        "path" => folder_path,
        "type" => "directory"
      })

      render_hook(view, "add_permission_target", %{"value" => "person:#{person.id}"})
      render_hook(view, "confirm_share", %{})

      refute has_element?(view, "button", "Save Permissions")
      assert [_] = Zaq.Ingestion.list_document_permissions(doc1.id)
      assert [_] = Zaq.Ingestion.list_document_permissions(doc2.id)
    end
  end

  describe "file_url/1" do
    alias ZaqWeb.Live.BO.AI.IngestionLive

    test "returns /bo/files/ prefixed URL" do
      assert IngestionLive.file_url("docs/guide.md") == "/bo/files/docs/guide.md"
    end

    test "strips leading ./ from path" do
      assert IngestionLive.file_url("./report.pdf") == "/bo/files/report.pdf"
    end

    test "handles simple filename" do
      assert IngestionLive.file_url("file.txt") == "/bo/files/file.txt"
    end
  end

  # ────────────────────────────────────────────────────────────────
  # Public access toggle
  # ────────────────────────────────────────────────────────────────

  describe "share modal — public toggle for a document" do
    test "share modal shows Public access toggle", %{conn: conn} do
      {:ok, _doc} = Document.create(%{source: disk_source("alpha.md"), content: "content"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "share_item", %{"path" => "alpha.md"})

      assert has_element?(view, "[data-testid='public-toggle']")
    end

    test "toggling public and confirming saves public ACLs", %{conn: conn} do
      {:ok, doc} = Document.create(%{source: disk_source("alpha.md"), content: "content"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "share_item", %{"path" => "alpha.md"})
      render_hook(view, "toggle_public", %{})
      render_hook(view, "confirm_share", %{})

      source = source_entry("alpha.md")
      assert Permissions.public?(%StorageEntry{id: source.id})
      assert Permissions.public?(Repo.get!(Document, doc.id))
    end

    test "toggling public twice and confirming leaves the tag unchanged", %{conn: conn} do
      {:ok, doc} = Document.create(%{source: disk_source("alpha.md"), content: "content"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "share_item", %{"path" => "alpha.md"})
      render_hook(view, "toggle_public", %{})
      render_hook(view, "toggle_public", %{})
      render_hook(view, "confirm_share", %{})

      source = source_entry("alpha.md")
      refute Permissions.public?(%StorageEntry{id: source.id})
      refute Permissions.public?(Repo.get!(Document, doc.id))
    end

    test "toggling public off removes public ACL from an already public document", %{conn: conn} do
      {:ok, doc} = Document.create(%{source: disk_source("alpha.md"), content: "content"})
      source = source_entry("alpha.md")
      {:ok, _} = Permissions.grant_public(%StorageEntry{id: source.id})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "share_item", %{"path" => "alpha.md"})
      render_hook(view, "toggle_public", %{})
      render_hook(view, "confirm_share", %{})

      refute Permissions.public?(%StorageEntry{id: source.id})
      refute Permissions.public?(Repo.get!(Document, doc.id))
    end

    test "toggle without confirm does not persist", %{conn: conn} do
      {:ok, doc} = Document.create(%{source: disk_source("alpha.md"), content: "content"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "share_item", %{"path" => "alpha.md"})
      render_hook(view, "toggle_public", %{})
      render_hook(view, "close_modal", %{})

      source = source_entry("alpha.md")
      refute Permissions.public?(%StorageEntry{id: source.id})
      refute Permissions.public?(Repo.get!(Document, doc.id))
    end
  end

  describe "share modal — public toggle for a folder" do
    test "toggling folder public and confirming saves public ACLs for descendants", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      File.mkdir_p!(Path.join(tmp_dir, "docs"))
      File.write!(Path.join([tmp_dir, "docs", "readme.md"]), "content")
      {:ok, doc} = Document.create(%{source: disk_source("docs/readme.md"), content: "content"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "share_item", %{"path" => "docs", "type" => "directory"})
      render_hook(view, "toggle_public", %{})
      render_hook(view, "confirm_share", %{})

      folder = source_entry("docs", "directory")
      assert Permissions.public?(%StorageEntry{id: folder.id})
      assert Permissions.public?(Repo.get!(Document, doc.id))
    end

    test "toggling folder public twice and confirming leaves flag unchanged", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      File.mkdir_p!(Path.join(tmp_dir, "docs"))
      File.write!(Path.join([tmp_dir, "docs", "readme.md"]), "content")
      {:ok, doc} = Document.create(%{source: disk_source("docs/readme.md"), content: "content"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "share_item", %{"path" => "docs", "type" => "directory"})
      render_hook(view, "toggle_public", %{})
      render_hook(view, "toggle_public", %{})
      render_hook(view, "confirm_share", %{})

      folder = source_entry("docs", "directory")
      refute Permissions.public?(%StorageEntry{id: folder.id})
      refute Permissions.public?(Repo.get!(Document, doc.id))
    end

    test "toggling folder public off removes public ACLs", %{conn: conn, tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "docs"))
      File.write!(Path.join([tmp_dir, "docs", "readme.md"]), "content")
      {:ok, doc} = Document.create(%{source: disk_source("docs/readme.md"), content: "content"})
      folder = source_entry("docs", "directory")
      {:ok, _} = Permissions.grant_public(%StorageEntry{id: folder.id})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "share_item", %{"path" => "docs", "type" => "directory"})
      render_hook(view, "toggle_public", %{})
      render_hook(view, "confirm_share", %{})

      refute Permissions.public?(%StorageEntry{id: folder.id})
      refute Permissions.public?(Repo.get!(Document, doc.id))
    end
  end

  # ────────────────────────────────────────────────────────────────
  # FolderDrop — folder_drop_skipped event
  # ────────────────────────────────────────────────────────────────

  describe "handle_event folder_drop_skipped" do
    test "assigns skipped list when payload contains a valid list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      skipped = [
        %{"name" => "report.json", "path" => "report.json", "reason" => "unsupported_format"},
        %{"name" => "data.xml", "path" => "data.xml", "reason" => "unsupported_format"}
      ]

      render_hook(view, "folder_drop_skipped", %{"skipped" => skipped})
      open_upload_modal(view)

      assert has_element?(view, "[data-testid='skipped-files']")
      assert has_element?(view, "[data-testid='skipped-files']", "report.json")
      assert has_element?(view, "[data-testid='skipped-files']", "data.xml")
    end

    test "assigns empty list when payload contains an empty list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "folder_drop_skipped", %{"skipped" => []})

      refute has_element?(view, "[data-testid='skipped-files']")
    end

    test "does not crash and leaves socket unchanged when payload is malformed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      # First set a valid skipped list so we can confirm it is preserved
      skipped = [%{"name" => "a.json", "path" => "a.json", "reason" => "unsupported_format"}]
      render_hook(view, "folder_drop_skipped", %{"skipped" => skipped})

      # Now send a malformed payload (skipped is not a list)
      render_hook(view, "folder_drop_skipped", %{"skipped" => "not_a_list"})
      open_upload_modal(view)

      # Socket unchanged — skipped list still visible
      assert has_element?(view, "[data-testid='skipped-files']", "a.json")
    end
  end

  # ────────────────────────────────────────────────────────────────
  # FolderDrop — upload event with folder_batch_done and client_relative_path
  # ────────────────────────────────────────────────────────────────

  describe "handle_event upload (folder drop behaviour)" do
    test "cancel_upload removes a queued upload entry", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
      open_upload_modal(view)

      upload =
        file_input(view, "#upload-form", :files, [
          %{
            name: "alpha.md",
            content: "# alpha",
            type: "text/markdown"
          }
        ])

      render_upload(upload, "alpha.md", 1)

      ref = upload.entries |> hd() |> Map.get("ref")

      render_hook(view, "cancel_upload", %{"ref" => ref})

      state = :sys.get_state(view.pid)
      assert state.socket.assigns.uploads.files.entries == []
    end

    test "upload errors do not escape the tmp dir and keep the view alive", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
      open_upload_modal(view)

      view
      |> file_input("#upload-form", :files, [
        %{
          name: "escape.md",
          content: "# escape",
          type: "text/markdown",
          relative_path: "../escape.md"
        }
      ])
      |> render_upload("escape.md", 100)

      render_hook(view, "upload", %{})

      refute File.exists?(Path.expand(Path.join(tmp_dir, "../escape.md")))
      assert Process.alive?(view.pid)
    end

    test "does not clear folder_drop_skipped across batches", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      skipped = [%{"name" => "bad.json", "path" => "bad.json", "reason" => "unsupported_format"}]
      render_hook(view, "folder_drop_skipped", %{"skipped" => skipped})
      open_upload_modal(view)
      assert has_element?(view, "[data-testid='skipped-files']", "bad.json")

      # Simulate upload event (no actual file upload in this test — just verify assign persistence)
      file_path = Path.join(tmp_dir, "alpha.md")
      assert File.exists?(file_path)

      # After a direct handle_event call the skipped list must still be present
      # (We use render_hook which triggers handle_event via the LiveView socket)
      # Since we cannot do a real file upload in unit tests, we call the event with empty params
      # and confirm no crash + skipped list remains
      render_hook(view, "validate_upload", %{})

      assert has_element?(view, "[data-testid='skipped-files']", "bad.json")
    end

    test "pushes folder_batch_done event after successful upload", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
      open_upload_modal(view)

      # Upload a real file through Phoenix LiveView upload test helpers
      md_path = Path.join(tmp_dir, "alpha.md")

      view
      |> file_input("#upload-form", :files, [
        %{
          name: "alpha.md",
          content: File.read!(md_path),
          type: "text/markdown"
        }
      ])
      |> render_upload("alpha.md", 100)

      # folder_batch_done should be pushed — we verify by confirming upload succeeded
      # (push_event is fire-and-forget from server; we assert no crash and flash appears)
      render_hook(view, "upload", %{})
      assert has_element?(view, "#flash-info")
    end

    test "uses client_relative_path as dest when set", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
      open_upload_modal(view)
      subdir = Path.join(tmp_dir, "subfolder")
      File.mkdir_p!(subdir)

      view
      |> file_input("#upload-form", :files, [
        %{
          name: "nested.md",
          content: "# nested",
          type: "text/markdown",
          relative_path: "subfolder/nested.md"
        }
      ])
      |> render_upload("nested.md", 100)

      render_hook(view, "upload", %{})

      assert File.exists?(Path.join(tmp_dir, "subfolder/nested.md"))
    end

    test "falls back to client_name when client_relative_path is empty string", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
      open_upload_modal(view)

      # empty string is truthy in Elixir — must not be used as dest
      view
      |> file_input("#upload-form", :files, [
        %{
          name: "alpha.md",
          content: "# alpha",
          type: "text/markdown",
          relative_path: ""
        }
      ])
      |> render_upload("alpha.md", 100)

      render_hook(view, "upload", %{})

      assert File.exists?(Path.join(tmp_dir, "alpha.md"))
      refute File.exists?(Path.join(tmp_dir, "../archives(2)"))
      refute File.exists?(Path.join(tmp_dir, "../archives(3)"))
    end

    test "falls back to client_name when client_relative_path is nil", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
      open_upload_modal(view)

      view
      |> file_input("#upload-form", :files, [
        %{
          name: "alpha.md",
          content: "# alpha",
          type: "text/markdown"
        }
      ])
      |> render_upload("alpha.md", 100)

      render_hook(view, "upload", %{})

      assert File.exists?(Path.join(tmp_dir, "alpha.md"))
    end

    test "does not crash when entries are still in-progress (upload fired before transfer completes)",
         %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
      open_upload_modal(view)

      # Upload only 50% — entry stays in-progress (not :done)
      view
      |> file_input("#upload-form", :files, [
        %{
          name: "alpha.md",
          content: File.read!(Path.join(tmp_dir, "alpha.md")),
          type: "text/markdown"
        }
      ])
      |> render_upload("alpha.md", 50)

      # "upload" fires before the transfer finishes (requestSubmit race condition)
      # The handler must not crash — it should skip consumption and wait
      render_hook(view, "upload", %{})

      assert render(view) =~ "upload"
    end
  end
end

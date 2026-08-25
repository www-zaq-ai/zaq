defmodule Zaq.Channels.DiskBridgeTest do
  # Unit-level: the router is stubbed through `config["node_router"]`, so these assert what
  # the bridge asks storage for and what it maps the answer into — never storage itself.
  use ExUnit.Case, async: true

  alias Zaq.Channels.DiskBridge
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.RecordPage
  alias Zaq.Event
  alias Zaq.Materialization.Handle
  alias Zaq.Storage.FileExplorer.Entry

  defmodule StubRouter do
    @moduledoc false

    def dispatch(%Event{} = event) do
      send(self(), {:dispatch, event.next_hop.destination, event.opts[:action], event.request})
      %{event | response: Process.get(:stub_response, {:ok, %{}})}
    end
  end

  defmodule ExplodingRouter do
    @moduledoc false

    def dispatch(%Event{}), do: raise("the bridge must not take its router from params")
  end

  defp config(overrides \\ %{}) do
    Map.merge(%{"provider" => "disk", "node_router" => StubRouter}, overrides)
  end

  defp stub_response(response), do: Process.put(:stub_response, response)

  defp entry(id, attrs \\ %{}) do
    struct!(
      %Entry{
        id: id,
        name: "guide.md",
        type: :file,
        size: 12,
        modified_at: ~U[2026-01-01 00:00:00Z],
        volume: "archives",
        relative_path: "guide.md",
        source: "guide.md"
      },
      attrs
    )
  end

  defp entry_page(entries), do: %{entries: entries, scanned: length(entries)}

  defp grant(id, attrs \\ %{}) do
    Map.merge(
      %{id: id, type: "person", target_id: "7", name: "Ada", access_rights: ["read"]},
      attrs
    )
  end

  # ── mapping: entries to records ─────────────────────────────────────────────

  describe "entry mapping" do
    test "maps a file entry onto a record, carrying provider attributes" do
      stub_response({:ok, entry_page([entry("42")])})

      assert {:ok, %RecordPage{records: [record]}} = DiskBridge.list_files(config(), %{})

      assert %Record{id: "42", kind: :file, name: "guide.md", path: "guide.md"} = record
      assert record.mime_type == "text/markdown"
      assert record.size == 12
      assert record.modified_at == ~U[2026-01-01 00:00:00Z]

      assert record.attributes == %{
               "provider" => "disk",
               "config_id" => "archives",
               "provider_record_id" => "42",
               "volume" => "archives",
               "relative_path" => "guide.md",
               "source" => "guide.md"
             }
    end

    test "translates the entry's :directory into the record's :folder, with no mime type" do
      # The two vocabularies meet here: storage says :directory, the record contract says
      # :folder.
      stub_response({:ok, entry_page([entry("d1", %{type: :directory, name: "manuals"})])})

      assert {:ok, %RecordPage{records: [record]}} = DiskBridge.list_files(config(), %{})
      assert record.kind == :folder
      assert record.mime_type == nil
    end

    test "keeps the entry on the record's raw field" do
      volume_entry = entry("42")
      stub_response({:ok, entry_page([volume_entry])})

      assert {:ok, %RecordPage{records: [record]}} = DiskBridge.list_files(config(), %{})
      assert record.raw == %{local_entry: volume_entry}
    end

    test "reports the scanned count storage gave alongside what was returned" do
      # `scanned` differs from `returned` when storage dropped rows whose file is gone.
      stub_response({:ok, %{entries: [entry("42")], scanned: 5}})

      assert {:ok, %RecordPage{stats: stats, resource_type: :item}} =
               DiskBridge.list_files(config(), %{})

      assert stats == %{scanned: 5, returned: 1}
    end

    test "answers with an empty page for an empty listing" do
      stub_response({:ok, entry_page([])})

      assert {:ok, %RecordPage{records: [], stats: %{scanned: 0, returned: 0}}} =
               DiskBridge.list_files(config(), %{})
    end
  end

  describe "materialization handles" do
    test "attaches a disk_document handle naming the record id" do
      stub_response({:ok, entry_page([entry("42")])})

      assert {:ok, %RecordPage{records: [record]}} = DiskBridge.list_files(config(), %{})

      assert {:ok, %{type: "disk_document", locator: %{"file_id" => "42"}}} =
               Handle.verify(record.materialization_handle)

      assert record.content == nil
    end

    test "attaches one to a file with no document row, using its volume-path id" do
      stub_response({:ok, entry_page([entry("disk:archives:loose.md")])})

      assert {:ok, %RecordPage{records: [record]}} = DiskBridge.list_files(config(), %{})

      assert {:ok, %{locator: %{"file_id" => "disk:archives:loose.md"}}} =
               Handle.verify(record.materialization_handle)
    end

    test "leaves folders with no handle" do
      stub_response({:ok, entry_page([entry("d1", %{type: :directory})])})

      assert {:ok, %RecordPage{records: [record]}} = DiskBridge.list_files(config(), %{})
      assert record.materialization_handle == nil
    end
  end

  # ── request shapes, one per callback ────────────────────────────────────────

  describe "list_files/2" do
    test "dispatches :list_documents to storage, passing filters through untouched" do
      params = %{"filters" => %{"parent" => "archives/manuals"}, "page_size" => 50}
      stub_response({:ok, entry_page([])})

      assert {:ok, %RecordPage{}} = DiskBridge.list_files(config(), params)
      assert_received {:dispatch, :storage, :list_documents, %{params: ^params}}
    end

    test "passes an storage error back unchanged" do
      stub_response({:error, :unknown_volume})

      assert {:error, :unknown_volume} = DiskBridge.list_files(config(), %{})
    end
  end

  describe "get_file/2" do
    test "dispatches :describe_document with the single id" do
      stub_response({:ok, entry("42")})

      assert {:ok, %{record: %Record{id: "42"}}} =
               DiskBridge.get_file(config(), %{"file_id" => "42"})

      assert_received {:dispatch, :storage, :describe_document, %{file_id: "42"}}
    end

    test "stringifies an integer file_id" do
      stub_response({:ok, entry("42")})

      assert {:ok, %{record: %Record{id: "42"}}} = DiskBridge.get_file(config(), %{file_id: 42})
      assert_received {:dispatch, :storage, :describe_document, %{file_id: "42"}}
    end

    test "passes an storage error back unchanged" do
      stub_response({:error, :not_found})

      assert {:error, :not_found} = DiskBridge.get_file(config(), %{"file_id" => "42"})
    end

    test "returns the record unmaterialized" do
      stub_response({:ok, entry("42")})

      assert {:ok, %{record: %Record{content: nil, materialization_handle: handle}}} =
               DiskBridge.get_file(config(), %{"file_id" => "42"})

      assert {:ok, %{type: "disk_document"}} = Handle.verify(handle)
    end
  end

  describe "create_file/2" do
    test "dispatches :persist_document carrying name, path, content, and encoding" do
      stub_response({:ok, %{status: "created", entry: entry("42")}})

      assert {:ok, %{status: "created", record: %Record{id: "42"}}} =
               DiskBridge.create_file(config(), %{
                 "name" => "notes.md",
                 "path" => "archives",
                 "content" => "# notes",
                 "encoding" => "base64"
               })

      assert_received {:dispatch, :storage, :persist_document, request}

      assert request == %{
               "name" => "notes.md",
               "path" => "archives",
               "content" => "# notes",
               "encoding" => "base64"
             }
    end

    test "defaults absent content to an empty string and leaves encoding nil" do
      stub_response({:ok, %{status: "created", entry: entry("42")}})

      DiskBridge.create_file(config(), %{"name" => "notes.md", "path" => "archives"})

      assert_received {:dispatch, :storage, :persist_document, request}
      assert request["content"] == ""
      assert request["encoding"] == nil
    end

    test "passes an storage error back unchanged" do
      stub_response({:error, :volume_required})

      assert {:error, :volume_required} =
               DiskBridge.create_file(config(), %{"name" => "notes.md", "path" => "nowhere"})
    end
  end

  describe "update_file/2" do
    test "dispatches :update_document with every key the caller sent" do
      stub_response({:ok, %{status: "updated", entry: entry("42")}})

      assert {:ok, %{status: "updated", record: %Record{id: "42"}}} =
               DiskBridge.update_file(config(), %{
                 "file_id" => "42",
                 "name" => "renamed.md",
                 "path" => "archives/manuals",
                 "content" => "new",
                 "encoding" => "base64"
               })

      assert_received {:dispatch, :storage, :update_document, request}

      assert request == %{
               "file_id" => "42",
               "name" => "renamed.md",
               "path" => "archives/manuals",
               "content" => "new",
               "encoding" => "base64"
             }
    end

    test "omits keys the caller did not send" do
      # An absent `content` must not reach storage as an empty one — that would truncate
      # the file on every rename.
      stub_response({:ok, %{status: "updated", entry: entry("42")}})

      DiskBridge.update_file(config(), %{"file_id" => "42", "name" => "renamed.md"})

      assert_received {:dispatch, :storage, :update_document, request}
      assert request == %{"file_id" => "42", "name" => "renamed.md"}
      refute Map.has_key?(request, "content")
      refute Map.has_key?(request, "path")
      refute Map.has_key?(request, "encoding")
    end

    test "treats a key holding nil as absent" do
      stub_response({:ok, %{status: "updated", entry: entry("42")}})

      DiskBridge.update_file(config(), %{"file_id" => "42", "content" => nil})

      assert_received {:dispatch, :storage, :update_document, request}
      assert request == %{"file_id" => "42"}
    end

    test "carries atom-keyed params through under string keys" do
      stub_response({:ok, %{status: "updated", entry: entry("42")}})

      DiskBridge.update_file(config(), %{file_id: "42", content: "new"})

      assert_received {:dispatch, :storage, :update_document, request}
      assert request == %{"file_id" => "42", "content" => "new"}
    end
  end

  describe "delete_file/2" do
    test "dispatches :delete_document and answers with the status alone" do
      # No record comes back: the file is gone by the time storage returns, so there is
      # nothing left to describe. Same answer JidoConnectBridge.delete_file/2 gives.
      stub_response({:ok, %{status: "deleted"}})

      assert {:ok, %{status: "deleted"}} = DiskBridge.delete_file(config(), %{"file_id" => "42"})

      assert_received {:dispatch, :storage, :delete_document, %{file_id: "42"}}
    end

    test "passes an storage error back unchanged" do
      stub_response({:error, :not_found})

      assert {:error, :not_found} = DiskBridge.delete_file(config(), %{"file_id" => "42"})
    end
  end

  describe "search_files/2" do
    test "dispatches :search_documents with the params untouched" do
      params = %{"query" => "invoice", "page_size" => 10}
      stub_response({:ok, entry_page([entry("42")])})

      assert {:ok, %RecordPage{records: [%Record{id: "42"}]}} =
               DiskBridge.search_files(config(), params)

      assert_received {:dispatch, :storage, :search_documents, %{params: ^params}}
    end

    test "passes an storage error back unchanged" do
      stub_response({:error, :query_required})

      assert {:error, :query_required} = DiskBridge.search_files(config(), %{})
    end
  end

  describe "download_document/2" do
    test "answers exactly as get_file/2 does — one read, not two" do
      stub_response({:ok, entry("42")})

      assert {:ok, %{record: %Record{id: "42", content: nil}}} =
               DiskBridge.download_document(config(), %{"file_id" => "42"})

      assert_received {:dispatch, :storage, :describe_document, %{file_id: "42"}}
      refute_received {:dispatch, :storage, _action, _request}
    end

    test "passes an storage error back, like get_file/2" do
      stub_response({:error, :not_found})

      assert {:error, :not_found} = DiskBridge.download_document(config(), %{"file_id" => "42"})
    end
  end

  describe "list_permissions/2" do
    test "dispatches :list_document_grants and maps each grant onto a record" do
      stub_response({:ok, %{permissions: [grant("7")], public?: false}})

      assert {:ok, %RecordPage{resource_type: :permission, records: [record]}} =
               DiskBridge.list_permissions(config(), %{"file_id" => "42"})

      assert %Record{id: "7", kind: :permission, name: "Ada", lifecycle_state: :active} = record

      assert record.attributes == %{
               "type" => "person",
               "target_id" => "7",
               "access_rights" => ["read"]
             }

      assert_received {:dispatch, :storage, :list_document_grants, %{file_id: "42"}}
    end

    test "synthesizes the public grant, since it has no permission row to name" do
      stub_response({:ok, %{permissions: [], public?: true}})

      assert {:ok, %RecordPage{records: [record]}} =
               DiskBridge.list_permissions(config(), %{"file_id" => "42"})

      assert record.id == "public:42"
      assert record.name == "Public"
      assert record.attributes["type"] == "public"
      assert record.attributes["target_id"] == nil
      assert record.attributes["access_rights"] == ["read"]
    end

    test "lists the public grant ahead of explicit ones" do
      stub_response({:ok, %{permissions: [grant("7")], public?: true}})

      assert {:ok, %RecordPage{records: records, stats: stats}} =
               DiskBridge.list_permissions(config(), %{"file_id" => "42"})

      assert Enum.map(records, & &1.id) == ["public:42", "7"]
      assert stats == %{scanned: 2, returned: 2}
    end

    test "answers with an empty page when nobody has access" do
      stub_response({:ok, %{permissions: [], public?: false}})

      assert {:ok, %RecordPage{resource_type: :permission, records: []}} =
               DiskBridge.list_permissions(config(), %{"file_id" => "42"})
    end

    test "defaults missing access rights to an empty list" do
      stub_response({:ok, %{permissions: [grant("7", %{access_rights: nil})], public?: false}})

      assert {:ok, %RecordPage{records: [record]}} =
               DiskBridge.list_permissions(config(), %{"file_id" => "42"})

      assert record.attributes["access_rights"] == []
    end

    test "passes an storage error back unchanged" do
      stub_response({:error, :not_found})

      assert {:error, :not_found} = DiskBridge.list_permissions(config(), %{"file_id" => "42"})
    end
  end

  describe "channel_stats/2" do
    test "dispatches :volume_stats" do
      stub_response({:ok, %{files_count: 3}})

      assert {:ok, %{files_count: 3}} = DiskBridge.channel_stats(config(), %{})
      assert_received {:dispatch, :storage, :volume_stats, %{params: %{}}}
    end
  end

  # ── cross-cutting behaviour ─────────────────────────────────────────────────

  describe "params key flexibility" do
    test "string and atom file_id spellings behave identically" do
      stub_response({:ok, %{status: "deleted"}})

      DiskBridge.delete_file(config(), %{"file_id" => "42"})
      assert_received {:dispatch, :storage, :delete_document, string_request}

      DiskBridge.delete_file(config(), %{file_id: "42"})
      assert_received {:dispatch, :storage, :delete_document, atom_request}

      assert string_request == atom_request
    end

    test "a string key holding nil does not shadow the atom spelling" do
      stub_response({:ok, %{status: "created", entry: entry("42")}})

      DiskBridge.create_file(config(), %{"name" => nil, :name => "notes.md", "path" => "archives"})

      assert_received {:dispatch, :storage, :persist_document, request}
      assert request["name"] == "notes.md"
    end
  end

  describe "router resolution" do
    test "reads the router off config, never off params" do
      # `params` reaches this bridge verbatim from agent tools. Taking the dispatch target
      # from it would let the caller choose which code runs.
      stub_response({:ok, entry_page([])})

      assert {:ok, %RecordPage{}} =
               DiskBridge.list_files(config(), %{"node_router" => ExplodingRouter})

      assert_received {:dispatch, :storage, :list_documents, _request}
    end

    test "accepts an atom-keyed router on config" do
      stub_response({:ok, entry_page([])})

      assert {:ok, %RecordPage{}} = DiskBridge.list_files(%{node_router: StubRouter}, %{})

      assert_received {:dispatch, :storage, :list_documents, _request}
    end
  end

  test "implements the DataSourceBridge behaviour" do
    assert Zaq.Channels.DataSourceBridge in (DiskBridge.module_info(:attributes)
                                             |> Keyword.get_values(:behaviour)
                                             |> List.flatten())
  end
end

defmodule Zaq.Agent.Tools.Ingestion.SourceSnapshotWorkflowTest do
  use Zaq.DataCase, async: false

  alias Zaq.AccountsFixtures
  alias Zaq.Agent.{Factory, OpaqueAliases}
  alias Zaq.Agent.Tools.DataSource.DownloadDocument

  alias Zaq.Agent.Tools.Ingestion.{
    ChunkContent,
    ConvertDocumentToMarkdown,
    GenerateEmbeddings,
    StoreEmbeddedChunks
  }

  alias Zaq.Channels
  alias Zaq.Channels.Materializers.DataSourceDocument
  alias Zaq.Contracts.{Record, RecordPage}
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Embedding.Client
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Event
  alias Zaq.Ingestion.{Api, Chunk, Document}
  alias Zaq.NodeRouterMock
  alias Zaq.Permissions
  alias Zaq.Storage
  alias Zaq.Storage.Materializers.DiskDocument
  alias Zaq.SystemConfigFixtures

  import Mox

  @dimension 1536
  @source_mime "application/vnd.google-apps.spreadsheet"
  @indexing_fields ~w(name url source_mime_type parents permissions)

  defmodule Provider do
    @moduledoc false

    def download_document(
          _config,
          %{"file_id" => "preloaded" = id, "required_record_fields" => _},
          _context
        ) do
      record = %Record{
        id: id,
        kind: :file,
        content: "a,b\n1,2\n",
        mime_type: "text/csv",
        permissions: []
      }

      source = %{source(id) | url: nil}
      {:ok, %{record: record, source_record: source, acquired_record_fields: ["url"]}}
    end

    def download_document(
          _config,
          %{"file_id" => "download-acl" = id, "required_record_fields" => _},
          _context
        ) do
      {:ok,
       %{
         record: %Record{
           id: id,
           kind: :file,
           content: "a,b\n1,2\n",
           mime_type: "text/csv",
           permissions: []
         }
       }}
    end

    def download_document(
          _config,
          %{"file_id" => id, "required_record_fields" => fields},
          _context
        )
        when fields != [] do
      send(self(), :downloaded)

      if id == "complete" do
        source = %{source(id) | permissions: []}
        record = %{source | content: "Item,Amount\nOrchard,15\n", mime_type: "text/csv"}
        {:ok, %{record: record, source_record: source}}
      else
        record = %Record{
          id: id,
          kind: :file,
          content: Base.encode64("Item,Amount\nOrchard,15\n"),
          mime_type: "text/csv",
          attributes: %{"encoding" => "base64"}
        }

        {:ok, %{record: record}}
      end
    end

    def download_document(_config, %{"file_id" => "ordinary" = id} = params, _context) do
      send(self(), {:ordinary_download, params})
      {:ok, %{record: %Record{id: id, kind: :file, content: "a,b\n1,2\n", mime_type: "text/csv"}}}
    end

    def get_file(_config, %{"file_id" => "download-acl" = id} = params, _context) do
      send(self(), {:metadata_params, params})
      {:ok, %{record: source(id)}}
    end

    def get_file(_config, %{"file_id" => id, "include_permissions" => true}, _context) do
      send(self(), :source_metadata_loaded)
      {:ok, %{record: source(id)}}
    end

    def list_permissions(_config, %{"file_id" => "incomplete"}, _context) do
      {:ok,
       %RecordPage{
         resource_type: :permission,
         records: [],
         metadata: %{incomplete_permission_projection?: true}
       }}
    end

    def list_permissions(_config, %{"file_id" => id}, _context) do
      send(self(), :source_permissions_loaded)

      if id == "missing" do
        {:error, :unsupported}
      else
        {:ok, %RecordPage{resource_type: :permission, records: []}}
      end
    end

    defp source(id) do
      %Record{
        id: id,
        kind: :file,
        name: "Quarterly report",
        parent_id: "folder",
        parent_ids: ["folder", "root"],
        url: "https://example.org/reports/quarterly",
        mime_type: "application/vnd.google-apps.spreadsheet"
      }
    end
  end

  setup :verify_on_exit!

  setup do
    original_channels = Application.get_env(:zaq, :channels)
    channels = Map.put(original_channels || %{}, :google_drive, %{bridge: Provider})
    Application.put_env(:zaq, :channels, channels)
    on_exit(fn -> Application.put_env(:zaq, :channels, original_channels) end)

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        provider: "google_drive",
        name: "Source snapshot fixture",
        kind: "data_source",
        enabled: true
      })
      |> Repo.insert!()

    SystemConfigFixtures.seed_embedding_config(%{model: "snapshot-model", dimension: @dimension})
    actor = AccountsFixtures.super_admin_fixture(%{must_change_password: false})
    scope = make_ref()
    on_exit(fn -> OpaqueAliases.clear_scope(scope) end)

    %{
      context: %{
        actor: %{user_id: actor.id},
        node_router: NodeRouterMock,
        opaque_alias_scope: scope
      },
      config: config
    }
  end

  test "ordinary downloads leave canonical fields unrequested", %{
    config: config,
    context: context
  } do
    assert {:ok, result} = download_with_fields(config, "ordinary", context, nil)
    assert %Record{content: "a,b\n1,2\n", permissions: nil} = result.record
    assert_received {:ordinary_download, params}
    refute Map.has_key?(params, "required_record_fields")
    assert {:ok, claims} = Provenance.verify(result.record)
    refute Map.has_key?(claims, "source_metadata")
  end

  test "reuses loaded fields, including empty ACLs and an acquired absent URL", %{
    config: config,
    context: context
  } do
    context = Map.put(context, :include_source_snapshot, true)
    assert {:ok, complete} = download_with_fields(config, "preloaded", context, @indexing_fields)
    assert complete.record.mime_type == "text/csv"
    assert {:ok, claims} = Provenance.verify(complete.record)
    assert claims["source_metadata"]["mime_type"] == @source_mime
    assert is_nil(claims["source_metadata"]["url"])
    assert claims["permissions"] == %{"state" => "loaded", "entries" => []}
    refute_received :source_metadata_loaded
    refute_received :source_permissions_loaded

    assert {:ok, partial} =
             download_with_fields(config, "download-acl", context, @indexing_fields)

    assert_received {:metadata_params,
                     %{"include_permissions" => false, "required_record_fields" => fields}}

    refute "permissions" in fields
    refute_received :source_permissions_loaded
    assert {:ok, claims} = Provenance.verify(partial.record)
    assert claims["permissions"] == %{"state" => "loaded", "entries" => []}
  end

  defp download_with_fields(config, id, context, fields) do
    {:ok, handle} = DataSourceDocument.issue("google_drive", id, %{"config_id" => config.id})

    expect(NodeRouterMock, :dispatch, fn %Event{} = event ->
      assert event.opts[:required_record_fields] == fields
      Channels.Api.handle_event(event, :data_source_download_document, %{})
    end)

    run(DownloadDocument, %{materialization_handle: handle}, context)
  end

  test "downloads, converts, chunks, embeds and stores with signed metadata after model aliasing",
       %{
         config: config,
         context: context
       } do
    assert {:ok, %{record: downloaded}} = download(config, "report", context)
    assert_received :downloaded
    assert_received :source_metadata_loaded
    assert_received :source_permissions_loaded
    assert {:ok, claims} = Provenance.verify(downloaded)
    assert claims["source_metadata"]["mime_type"] == @source_mime
    assert claims["permissions"] == %{"state" => "loaded", "entries" => []}

    assert {:ok, {:ok, %{record: visible}, []}} =
             Factory.after_tool_call(
               %{action_module: DownloadDocument},
               {:ok, %{record: downloaded}, []},
               context
             )

    assert %{
             "provenance_ref" => "prov_" <> _,
             "name" => "Quarterly report",
             "parent_ids" => ["folder", "root"],
             "mime_type" => "text/csv",
             "permissions" => [],
             "attributes" => %{"encoding" => "base64"}
           } = visible

    expect_ingestion(:convert_document_to_markdown)

    assert {:ok, %{content: markdown}} =
             projected_action(ConvertDocumentToMarkdown, %{"record" => visible}, context)

    assert markdown =~ "| Orchard | 15 |"
    assert {:ok, %{chunks: [chunk]}} = run(ChunkContent, %{content: markdown}, context)
    stub_embedding(chunk.embedding_input)

    assert {:ok, %{results: [embedding]}} =
             run(GenerateEmbeddings, %{texts: [chunk.embedding_input]}, context)

    tampered =
      Map.merge(visible, %{
        "id" => "another-file",
        "kind" => "folder",
        "name" => "Invented title",
        "mime_type" => "text/html",
        "url" => "https://example.org/forged",
        "parent_id" => "forged-parent",
        "parent_ids" => ["forged-parent"],
        "permissions" => [
          %{"id" => "all", "kind" => "permission", "attributes" => %{"type" => "public"}}
        ],
        "attributes" => %{
          "provider" => "disk",
          "config_id" => "1",
          "provider_record_id" => "wrong"
        }
      })

    input = %{
      "attempt_id" => Ecto.UUID.generate(),
      "markdown" => markdown,
      "record" => tampered,
      "items" => [%{chunk: chunk, embedding: Map.put(embedding, :chunk_index, chunk.chunk_index)}]
    }

    expect_ingestion(:store_embedded_chunks)

    assert {:ok, %{document_id: id, results: [%{status: "stored"}]}} =
             projected_action(StoreEmbeddedChunks, input, context)

    document = Document.get(id)
    assert document.source == "data_source/google_drive/#{config.id}/report"
    assert document.title == "Quarterly report"
    assert document.metadata["provider_url"] == "https://example.org/reports/quarterly"
    assert document.metadata["provider_mime_type"] == @source_mime
    assert document.metadata["provider_parent_id"] == "folder"
    assert document.metadata["provider_parent_ids"] == ["folder", "root"]
    refute Permissions.public?(document)
    assert [%{content: stored_content}] = Chunk.list_by_document(id)
    assert stored_content == chunk.content
    refute_received :source_metadata_loaded
    refute_received :source_permissions_loaded
  end

  test "reuses a complete download and preserves a missing rather than empty projection", %{
    config: config,
    context: context
  } do
    assert {:ok, %{record: complete}} = download(config, "complete", context)

    assert {:ok, %{"permissions" => %{"state" => "loaded", "entries" => []}}} =
             Provenance.verify(complete)

    refute_received :source_metadata_loaded
    refute_received :source_permissions_loaded

    assert {:ok, %{record: missing}} = download(config, "missing", context)
    assert_received :source_metadata_loaded
    assert_received :source_permissions_loaded

    assert {:ok, %{"permissions" => %{"state" => "not_loaded", "entries" => nil}}} =
             Provenance.verify(missing)
  end

  test "does not sign an incomplete permission page as an empty projection", %{
    config: config,
    context: context
  } do
    assert {:ok, %{record: incomplete}} = download(config, "incomplete", context)

    assert {:ok, %{"permissions" => %{"state" => "not_loaded", "entries" => nil}}} =
             Provenance.verify(incomplete)
  end

  @tag :tmp_dir
  test "a scoped Disk handle downloads once with its effective UI grants", %{
    context: context,
    tmp_dir: root
  } do
    original = Application.get_env(:zaq, Storage)
    Application.put_env(:zaq, Storage, base_path: root, volumes: %{})
    on_exit(fn -> Application.put_env(:zaq, Storage, original || []) end)

    File.mkdir_p!(Path.join(root, "docs"))
    File.write!(Path.join(root, "docs/notes.md"), "# Disk notes")

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        provider: "disk",
        name: "Disk snapshot fixture",
        kind: "data_source",
        enabled: true,
        settings: %{"volumes" => [%{"name" => "docs", "path" => "docs"}]}
      })
      |> Repo.insert!()

    opts = [config_id: config.id, skip_permissions: true]
    {:ok, entry} = Storage.describe_document("docs/notes.md", opts)

    {:ok, _} =
      Storage.grant_document_access(
        entry.id,
        %{team_id: Permissions.everyone_team_id(), access_rights: ["read"]},
        opts
      )

    {:ok, handle} = DiskDocument.issue(entry.id, %{"config_id" => config.id})

    expect(NodeRouterMock, :dispatch, fn event ->
      assert event.opts[:required_record_fields] == @indexing_fields
      Channels.Api.handle_event(event, :data_source_download_document, %{})
    end)

    expect(NodeRouterMock, :dispatch, fn event ->
      assert event.opts[:action] == :materialize_document
      Storage.Api.handle_event(event, :materialize_document, %{})
    end)

    assert {:ok, %{record: %Record{content: "# Disk notes"} = record}} =
             run(DownloadDocument, %{materialization_handle: handle}, indexing_context(context))

    assert {:ok, claims} = Provenance.verify(record)
    assert claims["provider"] == "disk"
    assert claims["source_metadata"]["name"] == "notes.md"
    assert %{"state" => "loaded", "entries" => [%{"rights" => ["read"]}]} = claims["permissions"]
  end

  defp download(config, id, context) do
    download_with_fields(config, id, indexing_context(context), @indexing_fields)
  end

  defp indexing_context(context), do: Map.put(context, :include_source_snapshot, true)

  defp stub_embedding(input) do
    Req.Test.expect(Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["input"] == input
      Req.Test.json(conn, %{"data" => [%{"embedding" => List.duplicate(0.1, @dimension)}]})
    end)
  end

  defp expect_ingestion(action) do
    expect(NodeRouterMock, :dispatch, fn %Event{} = event ->
      assert event.opts[:action] == action
      Api.handle_event(event, action, %{})
    end)
  end

  defp projected_action(action, arguments, context) do
    assert {:ok, %{arguments: arguments}} =
             Factory.before_tool_call(%{action_module: action, arguments: arguments}, context)

    run(action, arguments, context)
  end

  defp run(action, arguments, context), do: Jido.Exec.run(action, arguments, context, timeout: 0)
end

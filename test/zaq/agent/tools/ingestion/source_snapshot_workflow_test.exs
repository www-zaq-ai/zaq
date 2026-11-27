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

  defmodule Provider do
    @moduledoc false

    def download_document(_config, %{"file_id" => id, "include_permissions" => true}, _context) do
      send(self(), :downloaded)

      record =
        if id == "complete" do
          %{
            source(id)
            | content: "Item,Amount\nOrchard,15\n",
              mime_type: "text/csv",
              permissions: []
          }
        else
          %Record{
            id: id,
            kind: :file,
            content: Base.encode64("Item,Amount\nOrchard,15\n"),
            mime_type: "text/csv",
            attributes: %{"encoding" => "base64"}
          }
        end

      {:ok, %{record: record}}
    end

    def get_file(_config, %{"file_id" => id, "include_permissions" => true}, _context) do
      send(self(), :source_metadata_loaded)
      {:ok, %{record: source(id)}}
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
      assert event.opts[:include_source_snapshot]
      Channels.Api.handle_event(event, :data_source_download_document, %{})
    end)

    expect(NodeRouterMock, :dispatch, fn event ->
      assert event.opts[:action] == :materialize_document
      Storage.Api.handle_event(event, :materialize_document, %{})
    end)

    assert {:ok, %{record: %Record{content: "# Disk notes"} = record}} =
             run(DownloadDocument, %{materialization_handle: handle}, context)

    assert {:ok, claims} = Provenance.verify(record)
    assert claims["provider"] == "disk"
    assert claims["source_metadata"]["name"] == "notes.md"
    assert %{"state" => "loaded", "entries" => [%{"rights" => ["read"]}]} = claims["permissions"]
  end

  defp download(config, id, context) do
    assert {:ok, handle} =
             DataSourceDocument.issue("google_drive", id, %{"config_id" => to_string(config.id)})

    expect(NodeRouterMock, :dispatch, fn %Event{} = event ->
      assert event.opts[:include_source_snapshot]
      Channels.Api.handle_event(event, :data_source_download_document, %{})
    end)

    run(DownloadDocument, %{materialization_handle: handle}, context)
  end

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

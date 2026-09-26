defmodule Zaq.Ingestion.RecordSourceTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  import Mox

  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Contracts.RecordPage
  alias Zaq.Ingestion.{DocumentProcessor, RecordSource}

  setup :verify_on_exit!

  @docx "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
  @xlsx "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  @pptx "application/vnd.openxmlformats-officedocument.presentationml.presentation"

  for {label, original_name, original_mime, downloaded_name, downloaded_mime, extension} <- [
        {"Google Doc export", "Budget", "application/vnd.google-apps.document", "Budget", @docx,
         ".docx"},
        {"Google Sheet export", "Budget", "application/vnd.google-apps.spreadsheet", "Budget",
         @xlsx, ".xlsx"},
        {"Google Slides export", "Budget", "application/vnd.google-apps.presentation", "Budget",
         @pptx, ".pptx"},
        {"artifact filename beats stale source", "Report.pdf", "application/pdf", "Report.docx",
         @docx, ".docx"},
        {"artifact MIME beats stale source", "Report.txt", "text/plain", "Report", @docx,
         ".docx"},
        {"Sheet MIME beats stale PDF", "Report.pdf", "application/pdf", "Report", @xlsx, ".xlsx"},
        {"Slides MIME beats stale text", "Report.txt", "text/plain", "Report", @pptx, ".pptx"},
        {"incompatible artifact suffix", "Report", nil, "Report.pdf", @docx, ".docx"},
        {"compatible alias", "Report.pdf", nil, "Report.JPEG", "image/jpeg", ".jpeg"},
        {"ordinary DOCX", "Report.docx", @docx, "Report.docx", @docx, ".docx"},
        {"PDF nil name", "Report", nil, nil, "application/pdf", ".pdf"},
        {"PDF blank name", "Report", nil, "", "application/pdf", ".pdf"},
        {"PDF extensionless name", "Report", nil, "Report", "application/pdf", ".pdf"},
        {"normalized MIME", "Report.txt", nil, "Report", " Application/PDF ; charset=binary",
         ".pdf"},
        {"missing MIME artifact", "Report.pdf", nil, "Report.DOCX", nil, ".docx"},
        {"blank MIME artifact", "Report.pdf", nil, "Report.XLSX", "  ", ".xlsx"},
        {"octet-stream artifact", "Report.pdf", nil, "Report.PPTX",
         " APPLICATION/OCTET-STREAM; x=y", ".pptx"},
        {"missing MIME source fallback", "Report.PDF", nil, nil, nil, ".pdf"},
        {"blank MIME source fallback", "Report.pdf", nil, "Report", " ", ".pdf"},
        {"octet-stream source fallback", "Report.pdf", nil, "Report", "application/octet-stream",
         ".pdf"},
        {"no representation metadata", "Report", "application/pdf", nil, nil, ".bin"},
        {"blank metadata", "Report", nil, "", " ", ".bin"},
        {"generic metadata", "Report", nil, nil, "application/octet-stream", ".bin"},
        {"unknown specific MIME", "Report.docx", @docx, "Report.docx",
         "application/x-zaq-unknown", ".bin"},
        {"unknown structured-suffix MIME", "Report.docx", @docx, "Report.zip",
         "application/vnd.zaq-unknown+zip", ".bin"},
        {"unsafe downloaded suffix", "Report", nil, "Report.pdf\\evil", "application/pdf",
         ".pdf"},
        {"unsafe suffix fallback", "Report.pdf", nil, "Report.bad suffix", nil, ".pdf"},
        {"unsafe original suffix", "Report.bad suffix", nil, nil, nil, ".bin"},
        {"trailing dot", "Report", nil, "Report.", nil, ".bin"}
      ] do
    test "materialize/2 artifact extension: #{label}" do
      source = %{
        external_record()
        | name: unquote(original_name),
          mime_type: unquote(original_mime)
      }

      assert_artifact(
        source,
        unquote(downloaded_name),
        unquote(downloaded_mime),
        unquote(extension)
      )
    end
  end

  property "stale source suffix cannot override a specific exported MIME" do
    check all(suffix <- string(:alphanumeric, min_length: 1, max_length: 12), max_runs: 30) do
      source = %{external_record() | name: "Report." <> suffix}
      assert_artifact(source, "Export", @docx, ".docx")
    end
  end

  test "converts a genuine extensionless Google DOCX export to readable Markdown" do
    expected_text = "ZAQ issue 568 genuine DOCX regression"
    fixture = File.read!("test/fixtures/offline_conversion/google_drive_docx_export.docx")

    source = %{
      external_record()
      | name: "Google Drive document export",
        mime_type: "application/vnd.google-apps.document"
    }

    downloaded = %Record{
      id: "provider-file-1",
      kind: :file,
      name: "Google Drive document export",
      mime_type: @docx,
      content: Base.encode64(fixture),
      attributes: %{"encoding" => "base64"}
    }

    expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
      assert event.opts[:action] == :data_source_download_document
      %{event | response: {:ok, %{record: downloaded}}}
    end)

    assert {:ok, materialized} = RecordSource.materialize(source, router_context())
    root = Path.dirname(materialized.path)
    on_exit(fn -> File.rm_rf!(root) end)

    assert Path.extname(materialized.path) == ".docx"

    assert {:ok, document, _indexed_payloads} =
             DocumentProcessor.prepare_file_chunks(
               materialized.path,
               materialized.processor_opts
             )

    assert document.content =~ expected_text
    refute String.starts_with?(document.content, "PK")
    refute document.content =~ "[Content_Types].xml"
    refute document.content =~ "word/document.xml"
  end

  defp assert_artifact(source, name, mime_type, extension) do
    bytes = <<0, 255, 42, 13, 10>>

    downloaded = %Record{
      id: "provider-file-1",
      kind: :file,
      name: name,
      mime_type: mime_type,
      content: Base.encode64(bytes),
      attributes: %{"encoding" => "base64"}
    }

    expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
      assert event.next_hop.destination == :channels
      assert event.opts[:action] == :data_source_download_document
      assert event.request.provider == "google_drive"
      assert event.request.params["file_id"] == "provider-file-1"
      %{event | response: {:ok, %{record: downloaded}}}
    end)

    assert {:ok, materialized} = RecordSource.materialize(source, router_context())
    root = Path.dirname(materialized.path)
    on_exit(fn -> File.rm_rf!(root) end)
    assert Path.extname(materialized.path) == extension
    assert File.read!(materialized.path) == bytes
    assert materialized.record == source
    assert materialized.cleanup_paths == [root]
    assert materialized.processor_opts[:document_title] == source.name

    assert materialized.processor_opts[:source_override] ==
             "data_source/google_drive/cfg-1/provider-file-1"

    assert materialized.processor_opts[:document_metadata]["provider"] == "google_drive"
  end

  defp external_record(attrs \\ %{}) do
    %Record{
      id: "file-1",
      kind: :file,
      name: "Report.pdf",
      mime_type: "application/pdf",
      url: "https://drive.example/report",
      attributes:
        Map.merge(
          %{
            "provider" => "google_drive",
            "config_id" => "cfg-1",
            "provider_record_id" => "provider-file-1"
          },
          attrs
        )
    }
  end

  defp router_context(extra \\ %{}), do: Map.put(extra, :node_router, Zaq.NodeRouterMock)

  test "normalizes record kinds without resolving provider paths" do
    record = %Record{
      id: "r1",
      kind: "directory",
      attributes: %{"provider" => "disk", "config_id" => "docs", "provider_record_id" => "r1"}
    }

    assert RecordSource.kind(record) == :folder
    assert RecordSource.kind(%Record{id: "folder", kind: "folder"}) == :folder
    assert RecordSource.job_path(record) == "data_source/disk/docs/r1"
  end

  test "from_storage_map/1 rejects non-map values" do
    assert RecordSource.from_storage_map(nil) == {:error, :invalid_source_record}
    assert RecordSource.from_storage_map([]) == {:error, :invalid_source_record}
  end

  test "records without provider config are unsupported as ingestion sources" do
    assert RecordSource.job_path(%Record{id: "r4", kind: :file, attributes: %{}}) == nil
  end

  test "list_children/1 dispatches external list request and inherits external attrs" do
    parent = external_record()

    child = %Record{
      id: "child-1",
      kind: :file,
      name: "Child.md",
      attributes: %{"custom" => "kept"}
    }

    expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
      assert event.next_hop.destination == :channels
      assert event.request.provider == "google_drive"
      assert event.actor == %{person_id: 123, skip_permissions: true}

      assert event.request.params == %{
               "config_id" => "cfg-1",
               "filters" => %{"parent" => "provider-file-1", "include_shared" => false},
               "include_permissions" => true
             }

      assert event.opts[:action] == :data_source_list_files
      assert event.opts[:data_source_bridge_module] == Zaq.Channels.DataSourceBridge

      %{event | response: {:ok, %RecordPage{resource_type: :folder, records: [child]}}}
    end)

    assert {:ok, [listed]} =
             RecordSource.list_children(
               parent,
               router_context(%{
                 actor: %{person_id: 123, skip_permissions: true}
               })
             )

    assert listed.id == "child-1"
    assert listed.attributes["custom"] == "kept"
    assert listed.attributes["provider"] == "google_drive"
    assert listed.attributes["config_id"] == "cfg-1"
    assert listed.attributes["provider_record_id"] == "child-1"
  end

  test "list_children/1 returns external dispatch errors unchanged" do
    parent = external_record()

    expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
      %{event | response: {:error, :connector_unavailable}}
    end)

    assert RecordSource.list_children(parent, router_context()) ==
             {:error, :connector_unavailable}
  end

  test "materialize/1 stores downloaded row records as temporary markdown" do
    record = external_record(%{"provider_record_id" => "sheet-1"})

    downloaded = %Record{
      id: "sheet-1",
      kind: :file,
      content: [%{"Name" => "Ada", "Score" => 10}, %{"Name" => "Grace", "Score" => 12}]
    }

    expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
      assert event.request.provider == "google_drive"

      assert event.request.params == %{
               "config_id" => "cfg-1",
               "file_id" => "sheet-1",
               "document_mime_type" => "application/pdf"
             }

      assert event.opts[:action] == :data_source_download_document
      %{event | response: {:ok, %{record: downloaded}}}
    end)

    assert {:ok, materialized} = RecordSource.materialize(record, router_context())
    assert materialized.record == record
    assert materialized.cleanup_paths == [Path.dirname(materialized.path)]
    assert File.read!(materialized.path) =~ "| Name | Score |"
    assert File.read!(materialized.path) =~ "| --- | --- |"
    assert File.read!(materialized.path) =~ "| Ada | 10 |"

    assert materialized.processor_opts[:source_override] ==
             "data_source/google_drive/cfg-1/sheet-1"

    assert materialized.processor_opts[:document_title] == "Report.pdf"
    assert materialized.processor_opts[:document_metadata]["provider"] == "google_drive"
  end

  test "materialize/1 propagates materialization-handle issuance errors" do
    record = %{external_record() | mime_type: {:invalid, :json}}

    assert RecordSource.materialize(record, router_context()) ==
             {:error, :invalid_materialization_locator}
  end

  test "materialize/1 handles empty row downloads as empty markdown" do
    record = external_record(%{"provider_record_id" => "sheet-empty"})

    downloaded = %Record{id: "sheet-empty", kind: :file, content: []}

    expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
      %{event | response: {:ok, %{record: downloaded}}}
    end)

    assert {:ok, materialized} = RecordSource.materialize(record, router_context())
    assert File.read!(materialized.path) == ""
    assert materialized.cleanup_paths == [Path.dirname(materialized.path)]
  end

  test "materialize/1 renders nil table cells as empty markdown" do
    record = external_record(%{"provider_record_id" => "nil-cell"})
    downloaded = %Record{id: "nil-cell", kind: :file, content: [%{"Nullable" => nil}]}

    expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
      %{event | response: {:ok, %{record: downloaded}}}
    end)

    assert {:ok, materialized} = RecordSource.materialize(record, router_context())
    assert File.read!(materialized.path) == "| Nullable |\n| --- |\n|  |"
    assert materialized.cleanup_paths == [Path.dirname(materialized.path)]
    assert Path.dirname(materialized.path) in materialized.cleanup_paths
  end

  test "materialize/1 converts non-map row downloads without Elixir inspect syntax" do
    record = external_record(%{"provider_record_id" => "rows"})

    downloaded = %Record{id: "rows", kind: :file, content: ["alpha", 123, %{bad: :shape}]}

    expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
      %{event | response: {:ok, %{record: downloaded}}}
    end)

    assert {:ok, materialized} = RecordSource.materialize(record, router_context())
    assert File.read!(materialized.path) == "alpha\n123\n{\"bad\":\"shape\"}"
  end

  test "materialize/1 renders nullable and nested row values as json-safe markdown" do
    record = external_record(%{"provider_record_id" => "json-safe"})

    downloaded = %Record{
      id: "json-safe",
      kind: :file,
      content: [
        %{
          "Name" => nil,
          "Tags" => ["elixir", 42, true, nil],
          "Meta" => %{uri: URI.parse("https://example.test/a"), active: false}
        }
      ]
    }

    expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
      %{event | response: {:ok, %{record: downloaded}}}
    end)

    assert {:ok, materialized} = RecordSource.materialize(record, router_context())

    content = File.read!(materialized.path)

    assert content =~ "|  |"
    assert content =~ "[\"elixir\",42,true,null]"
    assert content =~ "\"host\":\"example.test\""
    refute content =~ "%URI{"
  end

  test "materialize/1 safely stringifies unsupported markdown row values" do
    record = external_record(%{"provider_record_id" => "unsupported-rows"})

    downloaded = %Record{
      id: "unsupported-rows",
      kind: :file,
      content: [:draft, {:unsupported, :tuple}]
    }

    expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
      %{event | response: {:ok, %{record: downloaded}}}
    end)

    assert {:ok, materialized} = RecordSource.materialize(record, router_context())

    content = File.read!(materialized.path)

    assert content == "draft\n"
    refute content =~ "{:unsupported, :tuple}"
  end

  test "materialize/1 stores base64 downloads as original file and schedules cleanup" do
    pdf_record = external_record(%{"provider_record_id" => "pdf-no-name"})

    pdf_downloaded = %Record{
      id: "pdf-no-name",
      kind: :file,
      name: nil,
      mime_type: "application/pdf",
      content: Base.encode64("PDF bytes"),
      attributes: %{"encoding" => "base64"}
    }

    expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
      %{event | response: {:ok, %{record: pdf_downloaded}}}
    end)

    assert {:ok, materialized} = RecordSource.materialize(pdf_record, router_context())
    assert String.ends_with?(materialized.path, ".pdf")
    assert File.read!(materialized.path) == "PDF bytes"
    assert materialized.cleanup_paths == [Path.dirname(materialized.path)]

    blob_record = %{external_record(%{"provider_record_id" => "blob"}) | name: "blob"}

    blob_downloaded = %Record{
      id: "blob",
      kind: :file,
      name: "",
      content: Base.encode64("blob"),
      attributes: %{"encoding" => "base64"}
    }

    expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
      %{event | response: {:ok, %{record: blob_downloaded}}}
    end)

    assert {:ok, materialized} = RecordSource.materialize(blob_record, router_context())
    assert String.ends_with?(materialized.path, ".bin")
    assert materialized.cleanup_paths == [Path.dirname(materialized.path)]
  end

  test "materialize/1 derives PDF extension from MIME type" do
    source = %{external_record(%{"provider_record_id" => "pdf-mime"}) | name: "download"}

    downloaded = %Record{
      id: "pdf-mime",
      kind: :file,
      name: nil,
      mime_type: "application/pdf",
      content: Base.encode64("PDF bytes"),
      attributes: %{"encoding" => "base64"}
    }

    expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
      %{event | response: {:ok, %{record: downloaded}}}
    end)

    assert {:ok, materialized} = RecordSource.materialize(source, router_context())
    assert String.ends_with?(materialized.path, ".pdf")
    assert File.read!(materialized.path) == "PDF bytes"
    assert materialized.cleanup_paths == [Path.dirname(materialized.path)]
  end

  test "materialize/1 handles nil downloaded attributes" do
    source = external_record(%{"provider_record_id" => "plain-text"})

    downloaded = %Record{
      id: "plain-text",
      kind: :file,
      name: nil,
      content: "markdown",
      attributes: nil
    }

    expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
      %{event | response: {:ok, %{record: downloaded}}}
    end)

    assert {:ok, materialized} = RecordSource.materialize(source, router_context())
    assert String.ends_with?(materialized.path, ".md")
    assert File.read!(materialized.path) == "markdown"
  end

  test "materialize/1 preserves original extension for flat base64 materializations" do
    pdf_record = external_record(%{"provider_record_id" => "disk-pdf"})

    expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
      assert event.opts[:action] == :data_source_download_document

      %{event | response: {:ok, %{content: Base.encode64("PDF bytes"), encoding: "base64"}}}
    end)

    assert {:ok, materialized} = RecordSource.materialize(pdf_record, router_context())
    assert String.ends_with?(materialized.path, ".pdf")
    assert File.read!(materialized.path) == "PDF bytes"
  end

  test "materialize/1 uses bin extension for unnamed non-pdf base64 downloads" do
    record = %{external_record(%{"provider_record_id" => "raw"}) | name: "raw"}

    downloaded = %Record{
      id: "raw",
      kind: :file,
      name: nil,
      mime_type: "application/octet-stream",
      content: Base.encode64("raw bytes"),
      attributes: %{"encoding" => "base64"}
    }

    expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
      %{event | response: {:ok, %{record: downloaded}}}
    end)

    assert {:ok, materialized} = RecordSource.materialize(record, router_context())
    assert String.ends_with?(materialized.path, ".bin")
    assert File.read!(materialized.path) == "raw bytes"
    assert materialized.cleanup_paths == [Path.dirname(materialized.path)]
  end

  test "materialize/1 returns unsupported downloaded record errors" do
    expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
      %{event | response: {:ok, %{record: %Record{id: "bad", kind: :file, content: nil}}}}
    end)

    assert RecordSource.materialize(external_record(), router_context()) ==
             {:error, :unsupported_downloaded_record}
  end

  test "materialize/1 propagates invalid base64 decode errors" do
    expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
      %{
        event
        | response:
            {:ok,
             %{
               record: %Record{
                 id: "bad",
                 kind: :file,
                 content: "not-base64!",
                 attributes: %{"encoding" => "base64"}
               }
             }}
      }
    end)

    assert :error = RecordSource.materialize(external_record(), router_context())
  end

  test "serializes and deserializes storage maps with datetime fallbacks" do
    datetime = ~U[2026-06-23 06:00:00Z]

    {:ok, record} =
      %Record{
        id: "r5",
        kind: :directory,
        name: "Docs",
        path: ".",
        mime_type: "inode/directory",
        size: 12,
        modified_at: datetime,
        materialization_handle: "signed-handle",
        attributes: %{"volume" => "docs"}
      }
      |> Provenance.seal(%{"provider" => "disk", "config_id" => "1"})

    storage = RecordSource.to_storage_map(record)
    assert storage["kind"] == "directory"
    assert storage["modified_at"] == DateTime.to_iso8601(datetime)
    assert storage["materialization_handle"] == "signed-handle"

    assert {:ok, decoded} = RecordSource.from_storage_map(storage)
    assert decoded.kind == :folder
    assert decoded.modified_at == datetime
    assert decoded.materialization_handle == "signed-handle"

    nil_storage = RecordSource.to_storage_map(%Record{id: "r7", kind: :file, modified_at: nil})
    assert nil_storage["modified_at"] == nil
    assert nil_storage["attributes"] == %{}

    {:ok, invalid_datetime_record} =
      %Record{id: "r6", kind: :file, modified_at: "not-a-date"}
      |> Provenance.seal(%{"provider" => "disk", "config_id" => "1"})

    assert {:ok, invalid_datetime} =
             invalid_datetime_record
             |> RecordSource.to_storage_map()
             |> RecordSource.from_storage_map()

    assert invalid_datetime.modified_at == "not-a-date"

    {:ok, nil_datetime_record} =
      %Record{id: "r8", kind: :folder, modified_at: nil}
      |> Provenance.seal(%{"provider" => "disk", "config_id" => "1"})

    assert {:ok, nil_datetime} =
             nil_datetime_record
             |> RecordSource.to_storage_map()
             |> RecordSource.from_storage_map()

    assert nil_datetime.kind == :folder
    assert nil_datetime.modified_at == nil

    storage =
      RecordSource.to_storage_map(%Record{
        id: "unsafe",
        kind: :directory,
        modified_at: "already-encoded",
        owners: :not_a_list,
        permissions: [
          %{id: "perm-1", emailAddress: "a@example.com", role: "reader", ignored: true},
          :not_a_map
        ],
        attributes: :not_a_map
      })

    assert storage["kind"] == "directory"
    assert storage["modified_at"] == "already-encoded"
    assert storage["owners"] == []
    assert storage["attributes"] == %{}

    assert storage["permissions"] == [
             %{"id" => "perm-1", "emailAddress" => "a@example.com", "role" => "reader"},
             %{}
           ]

    assert RecordSource.to_storage_map(%Record{
             id: "invalid-permissions",
             kind: :file,
             permissions: :invalid
           })["permissions"] ==
             []

    assert {:error, :invalid_source_record} =
             RecordSource.from_storage_map(%{
               "id" => "permissions",
               "kind" => :directory,
               "permissions" => [
                 %{"email" => "fallback@example.com"},
                 %{"display_name" => "Display", "email" => "email@example.com"}
               ]
             })

    assert {:error, :invalid_source_record} =
             RecordSource.from_storage_map(%{
               "id" => "bad-permissions",
               "kind" => "file",
               "permissions" => :not_a_list
             })

    assert RecordSource.kind(%Record{id: "r9", kind: :file}) == :file
    assert RecordSource.kind(%Record{id: "r10", kind: "file"}) == :file
    assert RecordSource.kind(%Record{id: "r11", kind: :spreadsheet}) == :spreadsheet

    assert RecordSource.from_storage_map(%{"kind" => "file"}) == {:error, :invalid_source_record}
  end
end

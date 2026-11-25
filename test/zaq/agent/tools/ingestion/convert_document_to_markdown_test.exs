defmodule Zaq.Agent.Tools.Ingestion.ConvertDocumentToMarkdownTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.DataSource.{CreateDocument, DownloadDocument}
  alias Zaq.Agent.Tools.Ingestion.ConvertDocumentToMarkdown
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Event
  alias Zaq.Ingestion.Api
  alias Zaq.Ingestion.{Document, DocumentConversion, IngestJob}
  alias Zaq.Ingestion.DocumentProcessor
  alias Zaq.Ingestion.Python.Pipeline
  alias Zaq.Ingestion.RecordSource
  alias Zaq.Repo

  @fixtures Path.expand("../../../../fixtures/offline_conversion", __DIR__)

  defmodule IngestionRouter do
    import ExUnit.Assertions

    def dispatch(%Event{actor: actor, opts: opts, request: %{source: source}} = event) do
      assert opts[:confidential]
      if source.record_id == "downloaded", do: assert(actor == %{person_id: "actor-1"})
      Api.handle_event(event, opts[:action], %{})
    end
  end

  test "converts a serialized download result and maps it to CreateDocument without indexing" do
    record = %Record{
      id: "downloaded",
      kind: :file,
      name: "report.csv",
      mime_type: "text/csv",
      content: Base.encode64("Item,Amount\nOrchard,15\n"),
      attributes: %{"encoding" => "base64"}
    }

    assert {:ok, signed} = Provenance.seal(record)
    assert {:ok, downloaded} = DownloadDocument.validate_output(%{record: signed})
    input = downloaded |> Jason.encode!() |> Jason.decode!()
    actor = %{person_id: "actor-1"}

    assert {:ok,
            %{
              name: "report.md",
              mime_type: "text/markdown",
              content: markdown,
              source: %{record_id: "downloaded", name: "report.csv", mime_type: "text/csv"}
            } = result} =
             Jido.Exec.run(ConvertDocumentToMarkdown, input, %{
               node_router: IngestionRouter,
               actor: actor
             })

    assert markdown =~ "| Orchard | 15 |"
    refute Repo.exists?(Document)
    refute Repo.exists?(IngestJob)

    args = result |> Map.take([:content, :name, :mime_type]) |> Map.put(:provider, "disk")
    assert {:ok, %{name: "report.md", content: ^markdown}} = CreateDocument.validate_params(args)
  end

  test "supports the default ignore mode on real Office downloads" do
    for {name, extension, expected} <- [
          {"google_drive_docx_export.docx", "docx", nil},
          {"pptx_text_slide.pptx", "pptx", "cobalt compass"},
          {"xlsx_data_table.xlsx", "xlsx", "silver orchard"}
        ] do
      downloaded = File.read!(Path.join(@fixtures, name))

      record = %Record{
        id: extension,
        kind: :file,
        name: name,
        mime_type: MIME.type(extension),
        content: Base.encode64(downloaded),
        attributes: %{"encoding" => "base64"}
      }

      assert {:ok, %{content: markdown}} = convert(record)
      assert String.trim(markdown) != ""
      refute markdown =~ "!["
      if expected, do: assert(markdown =~ expected)
    end
  end

  test "rejects modes before reading converter input" do
    for {name, mode} <- [
          {"letter.docx", "describe"},
          {"deck.pptx", "preserve"},
          {"book.xlsx", "describe"},
          {"report.pdf", "ignore"},
          {"report.csv", "ignore"}
        ] do
      record = %Record{id: "file", kind: :file, name: name, content: "not parseable"}
      assert {:error, :unsupported_image_handling} = DocumentConversion.to_markdown(record, mode)
    end
  end

  test "does not redeem an unmaterialized Record or accept arbitrary input types" do
    lazy = %Record{id: "image", kind: :file, name: "report.pdf", materialization_handle: "unused"}

    assert {:error, :materialized_file_required} = DocumentConversion.to_markdown(lazy)

    assert {:error, :unsupported_document_format} =
             DocumentConversion.to_markdown(%{lazy | name: "image.png", content: "not a picture"})

    assert {:error, :invalid_document_encoding} =
             DocumentConversion.to_markdown(%{
               lazy
               | content: "***",
                 attributes: %{"encoding" => "base64"}
             })
  end

  test "explicit PDF description fails before invoking Python when configuration is absent" do
    assert {:error, :image_description_unavailable} =
             Pipeline.run("no-such-file.pdf", api_key: "", require_image_descriptions: true)
  end

  test "uses the downloaded MIME type when a provider retains the original file name" do
    record = %Record{
      id: "export",
      kind: :file,
      name: "budget.xlsx",
      mime_type: "text/csv; charset=utf-8",
      content: "Item,Amount\nOrchard,15\n",
      attributes: %{"encoding" => "utf-8"}
    }

    assert {:ok, %{name: "budget.md", content: markdown}} = convert(record)
    assert markdown =~ "| Orchard | 15 |"
  end

  test "round-trips producer UTF-8 downloads through a serialized workflow value" do
    for {mime_type, input, expected} <- [
          {"text/csv", "Name,Count\nÉrable,2\n", "| Érable | 2 |"},
          {"text/markdown", "# Résumé\n", "# Résumé\n"}
        ] do
      assert {:ok, record} =
               Provenance.seal(%Record{
                 id: "export",
                 kind: :file,
                 mime_type: mime_type,
                 content: input,
                 attributes: %{"encoding" => "utf-8"}
               })

      assert {:ok, result} = DownloadDocument.validate_output(%{record: record})
      resumed = result |> Jason.encode!() |> Jason.decode!()
      context = %{node_router: IngestionRouter}

      assert {:ok, %{content: markdown}} =
               Jido.Exec.run(ConvertDocumentToMarkdown, resumed, context)

      assert markdown =~ expected
    end
  end

  test "records nested decode lifecycle without tracing the encoded or decoded payload" do
    parent = self()
    text = "# Confidential title"
    data = Base.encode64(text, padding: false)

    record = %Record{
      id: "notes",
      kind: :file,
      name: "notes.md",
      content: "\n#{data}\n",
      attributes: %{"encoding" => "base64"}
    }

    context = %{
      node_router: IngestionRouter,
      tool_call_id: "convert",
      on_tool_event: &send(parent, &1)
    }

    assert {:ok, %{content: ^text}} =
             Jido.Exec.run(ConvertDocumentToMarkdown, %{record: record}, context)

    assert_received %{kind: :tool_started, tool_name: "decode_base64", data: started}
    assert_received %{kind: :tool_completed, tool_name: "decode_base64", data: completed}
    assert started.parent_id == "convert"
    assert completed.outcome == "succeeded"

    for event <- [started, completed],
        payload <- [text, data],
        do: refute(inspect(event) =~ payload)
  end

  test "ingestion and standalone conversion produce the same CSV Markdown from a binary download" do
    record = %Record{
      id: "shared",
      kind: :file,
      name: "shared.xlsx",
      mime_type: "text/csv",
      content: Base.encode64("Fruit,Count\nÉrable,2\n"),
      attributes: %{"encoding" => "base64"}
    }

    assert {:ok, source} =
             Provenance.seal(%Record{
               id: "shared",
               kind: :file,
               name: "shared.xlsx",
               attributes: %{
                 "provider" => "google_drive",
                 "config_id" => "1",
                 "provider_record_id" => "shared"
               }
             })

    assert {:ok, %{content: markdown}} = convert(record)
    refute Repo.exists?(Document)

    Mox.expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      assert event.opts[:action] == :data_source_download_document
      %{event | response: {:ok, %{record: record}}}
    end)

    assert {:ok, staged} = RecordSource.materialize(source, %{node_router: Zaq.NodeRouterMock})
    on_exit(fn -> Enum.each(staged.cleanup_paths, &File.rm_rf/1) end)
    assert Path.extname(staged.path) == ".csv"

    assert {:ok, %Document{content: ^markdown}, [_ | _]} =
             DocumentProcessor.prepare_file_chunks(staged.path, staged.processor_opts)
  end

  test "passes through a Markdown download without a converter or image mode" do
    markdown = "# Notes\n\nSee the [source](https://example.org)."
    record = %Record{id: "notes", kind: :file, name: "notes.markdown", content: markdown}

    assert {:ok, %{name: "notes.md", content: ^markdown}} = convert(record)
  end

  test "rejects oversized input and output before returning a workflow result" do
    record = %Record{
      id: "notes",
      kind: :file,
      name: "notes.md",
      content: :binary.copy("a", 20 * 1024 * 1024 + 1)
    }

    assert {:error, :document_too_large} = DocumentConversion.to_markdown(record)

    smaller = %{record | content: binary_part(record.content, 0, 5 * 1024 * 1024 + 1)}
    assert {:error, :markdown_too_large} = DocumentConversion.to_markdown(smaller)
  end

  defp convert(record),
    do:
      Jido.Exec.run(ConvertDocumentToMarkdown, %{record: record}, %{node_router: IngestionRouter})
end

defmodule Zaq.Agent.Tools.DataSource.DownloadDocumentTest do
  use Zaq.DataCase, async: true

  alias Jido.Action.Schema
  alias Zaq.Agent.Tools.DataSource.DownloadDocument
  alias Zaq.Channels.Materializers.DataSourceDocument
  alias Zaq.Contracts.Record
  alias Zaq.Event
  alias Zaq.Materialization
  alias Zaq.Materialization.Handle

  defmodule StubNodeRouter do
    def dispatch(%Event{request: %{provider: "google_drive", params: params}, opts: opts} = event) do
      send(self(), {:dispatch, event.next_hop.destination, opts[:action], params})

      %{
        event
        | response: {:ok, %{record: %{"id" => params["file_id"], "content" => "abc"}}}
      }
    end
  end

  defmodule ErrorNodeRouter do
    def dispatch(%Event{} = event), do: %{event | response: {:error, :timeout}}
  end

  defmodule UnexpectedNodeRouter do
    def dispatch(%Event{} = event), do: %{event | response: :weird_response}
  end

  describe "schema" do
    test "is a valid Zoi action schema" do
      assert :ok = Schema.validate_config_schema(DownloadDocument.schema())
      assert is_map(Schema.to_json_schema(DownloadDocument.schema()))
    end

    test "accepts a materialization handle input" do
      assert :ok = DownloadDocument.validate_input_mode(%{materialization_handle: "handle"})
    end

    test "accepts provider and document_id input" do
      assert :ok =
               DownloadDocument.validate_input_mode(%{
                 provider: "google_drive",
                 document_id: "f1"
               })
    end

    test "rejects missing, partial, and ambiguous input modes" do
      message = "provide either materialization_handle or provider with document_id"

      assert {:error, ^message} = DownloadDocument.validate_input_mode(%{})

      assert {:error, ^message} =
               DownloadDocument.validate_input_mode(%{provider: "google_drive"})

      assert {:error, ^message} = DownloadDocument.validate_input_mode(%{document_id: "f1"})

      assert {:error, ^message} =
               DownloadDocument.validate_input_mode(%{
                 materialization_handle: "handle",
                 provider: "google_drive",
                 document_id: "f1"
               })
    end

    test "pre-validation converts map params using the action schema" do
      assert {:ok, converted} =
               DownloadDocument.on_before_validate_params(%{
                 "provider" => "google_drive",
                 "document_id" => "f1",
                 "config_id" => "12",
                 "ignored" => "kept"
               })

      assert converted.provider == "google_drive"
      assert converted.document_id == "f1"
      assert converted.config_id == "12"
      assert converted["ignored"] == "kept"
    end

    test "pre-validation preserves non-map params" do
      assert {:ok, :raw_params} = DownloadDocument.on_before_validate_params(:raw_params)
    end

    test "rejects non-object input mode" do
      assert {:error, "download_document input must be an object"} =
               DownloadDocument.validate_input_mode(:raw_params)

      assert {:error, "download_document input must be an object"} =
               DownloadDocument.validate_input_mode(nil)
    end
  end

  test "materializes a signed handle" do
    assert {:ok, handle} =
             Materialization.issue("data_source_document", %{
               "provider" => "google_drive",
               "file_id" => "f1"
             })

    assert {:ok, %{record: %Record{} = record}} =
             DownloadDocument.run(%{materialization_handle: handle}, %{
               node_router: StubNodeRouter
             })

    assert record.id == "f1"
    assert record.content == "abc"
    assert_received {:dispatch, :channels, :data_source_download_document, %{"file_id" => "f1"}}
  end

  test "materializes a signed handle with an explicit export MIME override" do
    assert {:ok, handle} =
             Materialization.issue("data_source_document", %{
               "provider" => "google_drive",
               "file_id" => "f1"
             })

    assert {:ok, %{record: %Record{} = record}} =
             DownloadDocument.run(
               %{materialization_handle: handle, export_mime_type: "text/plain"},
               %{node_router: StubNodeRouter}
             )

    assert record.id == "f1"
    assert record.content == "abc"

    assert_received {:dispatch, :channels, :data_source_download_document,
                     %{"file_id" => "f1", "export_mime_type" => "text/plain"}}
  end

  test "provider and document_id mode issues then redeems a data-source handle" do
    assert {:ok, %{record: %Record{} = record}} =
             DownloadDocument.run(%{provider: "google_drive", document_id: "f1"}, %{
               node_router: StubNodeRouter
             })

    assert record.id == "f1"
    assert record.content == "abc"
    assert_received {:dispatch, :channels, :data_source_download_document, %{"file_id" => "f1"}}
  end

  test "provider mode preserves config and MIME options in the download request" do
    assert {:ok, _} =
             DownloadDocument.run(
               %{
                 provider: "google_drive",
                 document_id: "f1",
                 config_id: "12",
                 document_mime_type: "application/vnd.google-apps.document",
                 export_mime_type: "text/plain"
               },
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :channels, :data_source_download_document,
                     %{
                       "file_id" => "f1",
                       "config_id" => "12",
                       "document_mime_type" => "application/vnd.google-apps.document",
                       "export_mime_type" => "text/plain"
                     }}
  end

  test "provider mode keeps export MIME out of the signed locator" do
    assert {:ok, handle} =
             DataSourceDocument.issue("google_drive", "f1", %{
               "config_id" => "12",
               "document_mime_type" => "application/vnd.google-apps.document",
               "export_mime_type" => "text/plain"
             })

    assert {:ok, %{locator: locator}} = Handle.verify(handle)

    refute Map.has_key?(locator, "export_mime_type")
  end

  test "returns formatted errors" do
    assert {:error, "Data source document download failed: :timeout"} =
             DownloadDocument.run(%{provider: "google_drive", document_id: "f1"}, %{
               node_router: ErrorNodeRouter
             })

    assert {:error,
            "Data source document download failed: unexpected materialize response :weird_response"} =
             DownloadDocument.run(%{provider: "google_drive", document_id: "f1"}, %{
               node_router: UnexpectedNodeRouter
             })
  end

  test "run returns an error when params do not contain a valid mode" do
    assert {:error, "Provide either materialization_handle or provider with document_id"} =
             DownloadDocument.run(%{}, %{})

    assert {:error, "Provide either materialization_handle or provider with document_id"} =
             DownloadDocument.run(%{provider: "google_drive"}, %{})
  end

  # ── unmaterialized bridges (disk) ───────────────────────────────────────────

  describe "run/2 against a bridge answering unmaterialized" do
    # Stands in for the disk data source: the channels hop answers with metadata only, and
    # the bytes come back through a second hop straight to ingestion.
    defmodule DiskNodeRouter do
      @moduledoc false

      @files %{
        "guide.md" => {"text/markdown", "# guide", %{}},
        "deck.pdf" => {"application/pdf", "JVBERi0=", %{"encoding" => "base64"}}
      }

      def dispatch(%Event{request: %{provider: "disk", params: params}, opts: opts} = event) do
        file_id = params["file_id"]
        send(self(), {:first_hop, event.next_hop.destination, opts[:action], params})
        {mime_type, _content, _attributes} = Map.fetch!(@files, file_id)

        %{
          event
          | response:
              {:ok,
               %{
                 record: %Record{
                   id: file_id,
                   kind: :file,
                   name: file_id,
                   mime_type: mime_type,
                   content: nil,
                   attributes: %{"provider" => "disk"},
                   materializing_event:
                     Event.new(%{file_id: file_id}, :ingestion,
                       opts: [action: :materialize_record]
                     )
                 }
               }}
        }
      end

      # The second hop reads bytes off a volume and answers with those alone; the record the
      # first hop returned is what carries identity and metadata.
      def dispatch(%Event{request: %{file_id: file_id}, opts: opts} = event) do
        send(self(), {:second_hop, event.next_hop.destination, opts[:action], file_id})
        {_mime_type, content, attributes} = Map.fetch!(@files, file_id)

        %{
          event
          | response: {:ok, %{content: content, encoding: attributes["encoding"]}}
        }
      end
    end

    defmodule DiskFirstHopErrorRouter do
      @moduledoc false

      def dispatch(%Event{request: %{provider: "disk"}} = event) do
        send(self(), :first_hop)
        %{event | response: {:error, :not_found}}
      end

      def dispatch(%Event{} = event) do
        send(self(), :second_hop)
        %{event | response: {:ok, %{}}}
      end
    end

    test "takes the second hop and returns text content for a text file" do
      assert {:ok, %{record: %Record{} = record}} =
               DownloadDocument.run(%{provider: "disk", document_id: "guide.md"}, %{
                 node_router: DiskNodeRouter
               })

      assert record.content == "# guide"
      refute Map.has_key?(record.attributes, "encoding")

      assert_received {:first_hop, :channels, :data_source_download_document,
                       %{"file_id" => "guide.md"}}

      assert_received {:second_hop, :ingestion, :materialize_record, "guide.md"}
    end

    test "returns base64 content for a binary file, flagged in attributes" do
      assert {:ok, %{record: %Record{} = record}} =
               DownloadDocument.run(%{provider: "disk", document_id: "deck.pdf"}, %{
                 node_router: DiskNodeRouter
               })

      assert record.attributes["encoding"] == "base64"
      assert Base.decode64!(record.content) == "%PDF-"
    end

    test "a provider answering with content directly takes exactly one hop" do
      assert {:ok, %{record: %{"id" => "f1", "content" => "abc"}}} =
               DownloadDocument.run(%{provider: "google_drive", document_id: "f1"}, %{
                 node_router: StubNodeRouter
               })

      assert_received {:dispatch, :data_source_download_document, %{"file_id" => "f1"}}
      refute_received {:dispatch, _action, _params}
    end

    test "an error on the first hop is prefixed and no second hop is attempted" do
      assert {:error, "Data source document download failed: :not_found"} =
               DownloadDocument.run(%{provider: "disk", document_id: "guide.md"}, %{
                 node_router: DiskFirstHopErrorRouter
               })

      assert_received :first_hop
      refute_received :second_hop
    end

    test "still merges the optional mime type and config keys into the first request" do
      assert {:ok, _} =
               DownloadDocument.run(
                 %{
                   provider: "disk",
                   document_id: "guide.md",
                   document_mime_type: "text/markdown",
                   export_mime_type: "text/plain",
                   config_id: "12"
                 },
                 %{node_router: DiskNodeRouter}
               )

      assert_received {:first_hop, :channels, :data_source_download_document, params}

      assert params == %{
               "file_id" => "guide.md",
               "document_mime_type" => "text/markdown",
               "export_mime_type" => "text/plain",
               "config_id" => "12"
             }
    end
  end
end

defmodule Zaq.Agent.Tools.DataSource.DownloadDocumentTest do
  use Zaq.DataCase, async: true

  alias Jido.Action.Schema
  alias Zaq.Agent.Tools.DataSource.DownloadDocument
  alias Zaq.Contracts.Record
  alias Zaq.Event

  defmodule StubNodeRouter do
    def dispatch(%Event{request: %{provider: "google_drive", params: params}, opts: opts}) do
      send(self(), {:dispatch, opts[:action], params})

      %{
        Event.new(%{}, :channels)
        | response: {:ok, %{record: %{"id" => params["file_id"], "content" => "abc"}}}
      }
    end
  end

  defmodule StubNodeRouterOkPayload do
    def dispatch(%Event{request: %{provider: "google_drive", params: %{"file_id" => "f1"}}}) do
      %{
        Event.new(%{}, :channels)
        | response: {:ok, %{status: "ok", bytes: 123}}
      }
    end
  end

  defmodule StubNodeRouterErrorTuple do
    def dispatch(%Event{request: %{provider: "google_drive", params: %{"file_id" => "f1"}}}) do
      %{
        Event.new(%{}, :channels)
        | response: {:error, :timeout}
      }
    end
  end

  defmodule StubNodeRouterUnexpected do
    def dispatch(%Event{request: %{provider: "google_drive", params: %{"file_id" => "f1"}}}) do
      %{
        Event.new(%{}, :channels)
        | response: :weird_response
      }
    end
  end

  defmodule StubNodeRouterMaterializing do
    def dispatch(%Event{request: %{provider: "google_drive", params: params}, opts: opts}) do
      send(self(), {:dispatch, opts[:action], params})

      materializing_event =
        Event.new(%{file_id: params["file_id"]}, :channels,
          opts: [action: :read_materialized_bytes]
        )

      %{
        Event.new(%{}, :channels)
        | response:
            {:ok,
             %{
               record: %Record{
                 id: params["file_id"],
                 kind: :file,
                 content: nil,
                 materializing_event: materializing_event
               }
             }}
      }
    end

    def dispatch(%Event{request: %{file_id: "f1"}, opts: opts} = event) do
      send(self(), {:dispatch, opts[:action], event.request})
      %{event | response: {:ok, %{content: "materialized", encoding: "base64"}}}
    end
  end

  defmodule StubNodeRouterCurrentDownloadResponse do
    def dispatch(%Event{} = event) do
      send(self(), {:dispatch, event.opts[:action], event.request})

      downloaded = %Record{
        id: "f1",
        kind: :file,
        content: "materialized from current API",
        attributes: %{"encoding" => "base64"}
      }

      %{event | response: {:ok, %{record: downloaded}}}
    end
  end

  describe "schema" do
    test "is a valid Zoi action schema" do
      assert :ok = Schema.validate_config_schema(DownloadDocument.schema())
      assert is_map(Schema.to_json_schema(DownloadDocument.schema()))
    end

    test "accepts a metadata record input" do
      assert :ok =
               DownloadDocument.validate_input_mode(%{
                 record: %Record{id: "f1", kind: :file}
               })
    end

    test "accepts provider and document_id input" do
      assert :ok =
               DownloadDocument.validate_input_mode(%{
                 provider: "google_drive",
                 document_id: "f1"
               })
    end

    test "rejects missing input mode" do
      assert {:error, "provide either record or provider with document_id"} =
               DownloadDocument.validate_input_mode(%{})
    end

    test "rejects partial provider input mode" do
      assert {:error, "provide either record or provider with document_id"} =
               DownloadDocument.validate_input_mode(%{provider: "google_drive"})

      assert {:error, "provide either record or provider with document_id"} =
               DownloadDocument.validate_input_mode(%{document_id: "f1"})
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

    test "pre-validation leaves non-map params unchanged" do
      assert {:ok, :raw_params} = DownloadDocument.on_before_validate_params(:raw_params)
      assert {:ok, nil} = DownloadDocument.on_before_validate_params(nil)

      assert {:ok, [:not, :a, :map]} =
               DownloadDocument.on_before_validate_params([:not, :a, :map])
    end

    test "rejects non-object input mode" do
      assert {:error, "download_document input must be an object"} =
               DownloadDocument.validate_input_mode(:raw_params)

      assert {:error, "download_document input must be an object"} =
               DownloadDocument.validate_input_mode(nil)
    end
  end

  test "dispatches datasource download_document action" do
    assert {:ok, %{record: %{"id" => "f1", "content" => "abc"}}} =
             DownloadDocument.run(%{provider: "google_drive", document_id: "f1"}, %{
               node_router: StubNodeRouter
             })

    assert_received {:dispatch, :data_source_download_document, %{"file_id" => "f1"}}
  end

  test "passes config_id when present" do
    assert {:ok, _} =
             DownloadDocument.run(
               %{provider: "google_drive", document_id: "f1", config_id: "12"},
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_download_document,
                     %{"file_id" => "f1", "config_id" => "12"}}
  end

  test "passes document and export mime types when present" do
    assert {:ok, _} =
             DownloadDocument.run(
               %{
                 provider: "google_drive",
                 document_id: "f1",
                 document_mime_type: "application/vnd.google-apps.document",
                 export_mime_type: "text/plain"
               },
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_download_document,
                     %{
                       "file_id" => "f1",
                       "document_mime_type" => "application/vnd.google-apps.document",
                       "export_mime_type" => "text/plain"
                     }}
  end

  describe "run/2 response shapes" do
    test "returns ok payloads without record normalization" do
      result =
        DownloadDocument.run(%{provider: "google_drive", document_id: "f1"}, %{
          node_router: StubNodeRouterOkPayload
        })

      assert {:ok, %{status: "ok", bytes: 123}} = result
      refute match?({:ok, %{record: _}}, result)
    end

    test "returns formatted errors for error tuples" do
      assert {:error, "Data source document download failed: :timeout"} =
               DownloadDocument.run(%{provider: "google_drive", document_id: "f1"}, %{
                 node_router: StubNodeRouterErrorTuple
               })
    end

    test "returns formatted errors for unexpected responses" do
      assert {:error, "Unexpected data source response: :weird_response"} =
               DownloadDocument.run(%{provider: "google_drive", document_id: "f1"}, %{
                 node_router: StubNodeRouterUnexpected
               })
    end

    test "materializes unmaterialized record responses" do
      assert {:ok, %{record: %Record{} = record}} =
               DownloadDocument.run(%{provider: "google_drive", document_id: "f1"}, %{
                 node_router: StubNodeRouterMaterializing
               })

      assert record.id == "f1"
      assert record.content == "materialized"
      assert record.attributes["encoding"] == "base64"
      assert_received {:dispatch, :data_source_download_document, %{"file_id" => "f1"}}
      assert_received {:dispatch, :read_materialized_bytes, %{file_id: "f1"}}
    end

    test "consumes metadata records with materializing events" do
      event =
        Event.new(%{provider: "google_drive", params: %{"file_id" => "f1"}}, :channels,
          opts: [action: :data_source_download_document]
        )

      metadata_record = %Record{
        id: "f1",
        kind: :file,
        name: "Document.pdf",
        materializing_event: event
      }

      assert {:ok, %{record: %Record{} = record}} =
               DownloadDocument.run(%{record: metadata_record}, %{
                 node_router: StubNodeRouterCurrentDownloadResponse
               })

      assert record.id == "f1"
      assert record.name == "Document.pdf"
      assert record.content == "materialized from current API"
      assert record.attributes["encoding"] == "base64"

      assert_received {:dispatch, :data_source_download_document,
                       %{provider: "google_drive", params: %{"file_id" => "f1"}}}
    end

    test "run returns an error when params do not contain a record or provider document id" do
      assert {:error, "Provide either record or provider with document_id"} =
               DownloadDocument.run(%{}, %{})

      assert {:error, "Provide either record or provider with document_id"} =
               DownloadDocument.run(%{provider: "google_drive"}, %{})

      assert {:error, "Provide either record or provider with document_id"} =
               DownloadDocument.run(%{document_id: "f1"}, %{})
    end
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

      def dispatch(%Event{request: %{file_id: file_id}, opts: opts} = event) do
        send(self(), {:second_hop, event.next_hop.destination, opts[:action], file_id})
        {mime_type, content, attributes} = Map.fetch!(@files, file_id)

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
                   content: content,
                   attributes: Map.merge(%{"provider" => "disk"}, attributes)
                 }
               }}
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

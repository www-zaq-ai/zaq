defmodule Zaq.Agent.Tools.DataSource.DownloadDocumentTest do
  use Zaq.DataCase, async: true

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
      assert {:error, "Unexpected channel response: :weird_response"} =
               DownloadDocument.run(%{provider: "google_drive", document_id: "f1"}, %{
                 node_router: StubNodeRouterUnexpected
               })
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

    # Stands in for an inbound attachment: the disk record is an image, so what the tool
    # does with it depends entirely on what the running model can read.
    defmodule ImageNodeRouter do
      @moduledoc false

      def dispatch(%Event{request: %{provider: "disk", params: params}} = event) do
        send(self(), {:first_hop, params["file_id"]})

        %{
          event
          | response:
              {:ok,
               %{
                 record: %Record{
                   id: "42",
                   kind: :file,
                   name: "photo.png",
                   mime_type: "image/png",
                   content: nil,
                   materializing_event:
                     Event.new(%{file_id: "42"}, :ingestion, opts: [action: :materialize_record])
                 }
               }}
        }
      end

      def dispatch(%Event{request: %{file_id: "42"}} = event) do
        send(self(), :second_hop)

        %{
          event
          | response:
              {:ok,
               %{
                 record: %Record{
                   id: "42",
                   kind: :file,
                   name: "photo.png",
                   mime_type: "image/png",
                   content: Base.encode64("PNGBYTES"),
                   attributes: %{"encoding" => "base64"}
                 }
               }}
        }
      end
    end

    test "an image reaches a vision model as a real content part, not as base64 text" do
      assert {:ok, payload} =
               DownloadDocument.run(%{provider: "disk", document_id: "42"}, %{
                 node_router: ImageNodeRouter,
                 input_modalities: [:text, :image]
               })

      assert [%ReqLLM.Message.ContentPart{type: :image} = part] = payload.__content_parts__
      assert part.data == "PNGBYTES"
      assert part.media_type == "image/png"
    end

    test "a text-only model gets an explanation instead of the bytes" do
      assert {:ok, %{refused: message}} =
               DownloadDocument.run(%{provider: "disk", document_id: "42"}, %{
                 node_router: ImageNodeRouter,
                 input_modalities: [:text]
               })

      assert message =~ "cannot read image"
      refute Map.has_key?(%{refused: message}, :__content_parts__)
    end

    test "a declared image type is refused before any dispatch happens" do
      assert {:ok, %{refused: _message}} =
               DownloadDocument.run(
                 %{provider: "disk", document_id: "42", document_mime_type: "image/png"},
                 %{node_router: ImageNodeRouter, input_modalities: [:text]}
               )

      refute_received {:first_hop, _}
      refute_received :second_hop
    end

    test "a declared image type still downloads when the model can see it" do
      assert {:ok, payload} =
               DownloadDocument.run(
                 %{provider: "disk", document_id: "42", document_mime_type: "image/png"},
                 %{node_router: ImageNodeRouter, input_modalities: [:text, :image]}
               )

      assert [%ReqLLM.Message.ContentPart{type: :image}] = payload.__content_parts__
      assert_received {:first_hop, "42"}
    end

    test "an unknown modality list attempts the download rather than assuming blindness" do
      assert {:ok, payload} =
               DownloadDocument.run(%{provider: "disk", document_id: "42"}, %{
                 node_router: ImageNodeRouter,
                 input_modalities: []
               })

      assert %Record{} = payload.record
      assert_received {:first_hop, "42"}
    end

    test "a text document is unaffected by the modality check" do
      assert {:ok, payload} =
               DownloadDocument.run(%{provider: "disk", document_id: "guide.md"}, %{
                 node_router: DiskNodeRouter,
                 input_modalities: [:text]
               })

      assert payload.record.content == "# guide"
      refute Map.has_key?(payload, :__content_parts__)
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

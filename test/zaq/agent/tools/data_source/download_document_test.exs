defmodule Zaq.Agent.Tools.DataSource.DownloadDocumentTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.DataSource.DownloadDocument
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

  # The provider's payload is now normalized into a `%Record{}` — which is what the tool's
  # output_schema has always promised ("a normalized record including document content").
  # Recognised fields are lifted off the provider map rather than dropped.
  test "dispatches datasource download_document action and normalizes the record" do
    assert {:ok, %{record: %{id: "f1", content: "abc"}}} =
             DownloadDocument.run(%{provider: "google_drive", document_id: "f1"}, %{
               node_router: StubNodeRouter
             })

    assert_received {:dispatch, :data_source_download_document, %{"file_id" => "f1"}}
  end

  test "lifts provider metadata onto the normalized record" do
    defmodule RichRouter do
      def dispatch(%Event{} = event) do
        %{
          event
          | response:
              {:ok,
               %{
                 record: %{
                   "id" => "f1",
                   "content" => "abc",
                   "name" => "prices.pdf",
                   "mime_type" => "application/pdf",
                   "size" => 12
                 }
               }}
        }
      end
    end

    assert {:ok, %{record: record}} =
             DownloadDocument.run(%{provider: "google_drive", document_id: "f1"}, %{
               node_router: RichRouter
             })

    assert record.name == "prices.pdf"
    assert record.mime_type == "application/pdf"
    assert record.size == 12
  end

  # The event is what makes the record self-fetching, and it must never reach the model.
  # The projection drops the key entirely rather than nilling it.
  test "the returned record carries no materializing event" do
    assert {:ok, %{record: record}} =
             DownloadDocument.run(%{provider: "google_drive", document_id: "f1"}, %{
               node_router: StubNodeRouter
             })

    refute Map.has_key?(record, :materializing_event)
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

  # These exercise Jido's validation pipeline rather than `run/2` directly. Calling `run/2`
  # bypasses both hooks, so a schema that cannot accept a real tool call — or cannot accept
  # this action's own output — still passes every behavioural test.
  describe "Zoi schema at the tool boundary" do
    test "accepts the string-keyed params a model actually sends" do
      assert {:ok, %{provider: "disk", document_id: "42"}} =
               DownloadDocument.validate_params(%{"provider" => "disk", "document_id" => "42"})
    end

    test "accepts atom-keyed params from internal callers" do
      assert {:ok, %{provider: "disk", document_id: "42"}} =
               DownloadDocument.validate_params(%{provider: "disk", document_id: "42"})
    end

    test "carries optional params through" do
      assert {:ok, %{config_id: "7"}} =
               DownloadDocument.validate_params(%{
                 "provider" => "disk",
                 "document_id" => "42",
                 "config_id" => "7"
               })
    end

    test "rejects a call missing a required param" do
      assert {:error, _} = DownloadDocument.validate_params(%{"document_id" => "42"})
    end

    # Zoi's map type rejects structs, so the tool projects the record to a plain map before
    # returning. Validating the real output shape is what proves the two agree.
    test "accepts the output run/2 actually produces" do
      assert {:ok, output} =
               DownloadDocument.run(%{provider: "google_drive", document_id: "f1"}, %{
                 node_router: StubNodeRouter
               })

      assert {:ok, _} = DownloadDocument.validate_output(output)
    end

    # The projection goes through `Record.public_fields/0`, so the two fields that must
    # never reach a model cannot arrive by this route either.
    test "the returned record carries neither raw nor materializing_event" do
      assert {:ok, %{record: record}} =
               DownloadDocument.run(%{provider: "google_drive", document_id: "f1"}, %{
                 node_router: StubNodeRouter
               })

      refute Map.has_key?(record, :raw)
      refute Map.has_key?(record, :materializing_event)
      refute Map.has_key?(record, :__struct__)
    end
  end

  describe "run/2 response shapes" do
    # Previously a contentless success was passed straight through to the model. A download
    # that returned no bytes is not a successful download, and reporting it as one leaves
    # the model with a record it cannot read and no indication why.
    test "reports a success carrying no content as an error" do
      assert {:error, message} =
               DownloadDocument.run(%{provider: "google_drive", document_id: "f1"}, %{
                 node_router: StubNodeRouterOkPayload
               })

      assert message =~ "Data source document download failed"
    end

    test "returns formatted errors for error tuples" do
      assert {:error, "Data source document download failed: :timeout"} =
               DownloadDocument.run(%{provider: "google_drive", document_id: "f1"}, %{
                 node_router: StubNodeRouterErrorTuple
               })
    end

    # A response that is not even a result tuple never reaches this tool's own handling —
    # `DataSourceTool.dispatch/5` rejects it first, with the same message every datasource
    # tool gives for the same malformed answer. The payload is what identifies it.
    test "returns formatted errors for unexpected responses" do
      assert {:error, message} =
               DownloadDocument.run(%{provider: "google_drive", document_id: "f1"}, %{
                 node_router: StubNodeRouterUnexpected
               })

      assert message =~ "Unexpected data source response"
      assert message =~ "weird_response"
    end
  end

  # The tool is provider-shaped, not topology-shaped: it composes one stub record and hands
  # it to `Materializer`. Whether the provider answers with bytes in one hop or points at
  # the role that holds them is settled below the tool, so a provider switching from eager
  # to deferred must need no change here. These two assert exactly that.
  describe "providers that answer in more than one hop" do
    defmodule DeferringRouter do
      def dispatch(%Event{opts: opts} = event) do
        send(self(), {:dispatch, opts[:action]})

        case opts[:action] do
          # Channels fronts the `disk` provider, but the file is on an ingestion volume —
          # so it answers with what it knows and the event that fetches the rest.
          :data_source_download_document ->
            %{
              event
              | response:
                  {:ok,
                   %{
                     record: %Zaq.Contracts.Record{
                       id: "f1",
                       kind: :file,
                       name: "guide.md",
                       content: nil,
                       materializing_event:
                         Event.new(%{file_id: "f1"}, :ingestion,
                           opts: [action: :materialize_record]
                         )
                     }
                   }}
            }

          :materialize_record ->
            %{
              event
              | response: {:ok, %Zaq.Contracts.Record{id: "f1", kind: :file, content: "on disk"}}
            }
        end
      end
    end

    test "follows the redirect and returns the content to the model" do
      assert {:ok, %{record: record}} =
               DownloadDocument.run(%{provider: "disk", document_id: "f1"}, %{
                 node_router: DeferringRouter
               })

      assert record.content == "on disk"
      assert_received {:dispatch, :data_source_download_document}
      assert_received {:dispatch, :materialize_record}
    end

    # The hop that holds the bytes is not the hop that knows the filename. Losing it here
    # would hand the model content it cannot name.
    test "keeps metadata supplied by the redirecting hop" do
      assert {:ok, %{record: record}} =
               DownloadDocument.run(%{provider: "disk", document_id: "f1"}, %{
                 node_router: DeferringRouter
               })

      assert record.name == "guide.md"
      refute Map.has_key?(record, :materializing_event)
    end
  end
end

defmodule Zaq.Agent.Tools.GoogleDrive.DownloadDocumentTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.GoogleDrive.DownloadDocument
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
      assert {:error, "Unexpected data source response: :weird_response"} =
               DownloadDocument.run(%{provider: "google_drive", document_id: "f1"}, %{
                 node_router: StubNodeRouterUnexpected
               })
    end
  end
end

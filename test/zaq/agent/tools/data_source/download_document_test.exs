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
end

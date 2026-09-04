defmodule Zaq.Channels.Materializers.DataSourceDocumentTest do
  use Zaq.DataCase, async: true

  alias Zaq.Channels.Materializers.DataSourceDocument
  alias Zaq.Event
  alias Zaq.Materialization.Handle

  defmodule StubNodeRouter do
    def dispatch(%Event{request: %{provider: provider, params: params}, opts: opts} = event) do
      send(
        self(),
        {:dispatch, event.next_hop.destination, opts[:action], provider, params, event.actor,
         opts}
      )

      %{event | response: {:ok, %{content: "downloaded"}}}
    end
  end

  test "issues data-source document handles with identity locator fields" do
    assert {:ok, handle} =
             DataSourceDocument.issue("google_drive", "f1", %{
               "config_id" => "12",
               "document_mime_type" => "application/pdf",
               "export_mime_type" => "text/plain"
             })

    assert {:ok, %{type: "data_source_document", locator: locator}} = Handle.verify(handle)
    assert locator["provider"] == "google_drive"
    assert locator["file_id"] == "f1"
    assert locator["config_id"] == "12"
    assert locator["document_mime_type"] == "application/pdf"
    refute Map.has_key?(locator, "export_mime_type")
  end

  test "materializes through a fixed Channels download action" do
    assert {:ok, %{content: "downloaded"}} =
             DataSourceDocument.materialize(
               %{"provider" => "google_drive", "file_id" => "f1", "config_id" => "12"},
               %{node_router: StubNodeRouter, actor: %{person: %{id: 123}}}
             )

    assert_received {:dispatch, :channels, :data_source_download_document, "google_drive",
                     %{"file_id" => "f1", "config_id" => "12"}, %{person: %{id: 123}}, _opts}
  end

  test "materializes with an explicit export MIME runtime option" do
    assert {:ok, %{content: "downloaded"}} =
             DataSourceDocument.materialize(
               %{"provider" => "google_drive", "file_id" => "f1", "config_id" => "12"},
               %{node_router: StubNodeRouter},
               %{"export_mime_type" => "text/plain"}
             )

    assert_received {:dispatch, :channels, :data_source_download_document, "google_drive",
                     %{
                       "file_id" => "f1",
                       "config_id" => "12",
                       "export_mime_type" => "text/plain"
                     }, nil, _opts}
  end

  test "materializes with atom-key runtime options" do
    assert {:ok, %{content: "downloaded"}} =
             DataSourceDocument.materialize(
               %{"provider" => "google_drive", "file_id" => "f1", "config_id" => "12"},
               %{node_router: StubNodeRouter},
               %{document_mime_type: "application/pdf", export_mime_type: "text/plain"}
             )

    assert_received {:dispatch, :channels, :data_source_download_document, "google_drive",
                     %{
                       "file_id" => "f1",
                       "config_id" => "12",
                       "document_mime_type" => "application/pdf",
                       "export_mime_type" => "text/plain"
                     }, nil, _opts}
  end

  test "passes only an explicit trusted permission bypass through to Channels" do
    assert {:ok, %{content: "downloaded"}} =
             DataSourceDocument.materialize(
               %{"provider" => "disk", "file_id" => "f1", "config_id" => "12"},
               %{
                 node_router: StubNodeRouter,
                 skip_permissions: true,
                 event_opts: [skip_permissions: false, action: :delete_document]
               }
             )

    assert_received {:dispatch, :channels, :data_source_download_document, "disk", _params, nil,
                     opts}

    assert opts[:skip_permissions] == true
    assert opts[:action] == :data_source_download_document
  end

  test "rejects runtime options that try to override locator identity" do
    assert {:error, :invalid_materialization_options} =
             DataSourceDocument.materialize(
               %{"provider" => "google_drive", "file_id" => "f1", "config_id" => "12"},
               %{node_router: StubNodeRouter},
               %{"file_id" => "other"}
             )
  end

  test "rejects invalid locators" do
    assert {:error, :invalid_materialization_locator} =
             DataSourceDocument.materialize(%{"provider" => "google_drive"}, %{})

    assert {:error, :invalid_materialization_locator} =
             DataSourceDocument.materialize(%{"file_id" => "f1"}, %{})
  end
end

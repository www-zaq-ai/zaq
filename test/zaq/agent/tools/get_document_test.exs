defmodule Zaq.Agent.Tools.GetDocumentTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.GetDocument
  alias Zaq.Event

  defmodule StubNodeRouter do
    def dispatch(%Event{request: %{provider: "google_drive", params: params}, opts: opts}) do
      send(self(), {:dispatch, opts[:action], params})
      %{Event.new(%{}, :channels) | response: {:ok, %{record: %{"id" => params["file_id"]}}}}
    end
  end

  defmodule ErrorNodeRouter do
    def dispatch(%Event{}), do: %{Event.new(%{}, :channels) | response: {:error, :timeout}}
  end

  test "dispatches datasource get_file action" do
    assert {:ok, %{record: %{"id" => "f1"}}} =
             GetDocument.run(%{provider: "google_drive", document_id: "f1"}, %{
               node_router: StubNodeRouter
             })

    assert_received {:dispatch, :data_source_get_file, %{"file_id" => "f1"}}
  end

  test "passes config_id when present" do
    assert {:ok, _} =
             GetDocument.run(
               %{provider: "google_drive", document_id: "f1", config_id: "12"},
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_get_file, %{"file_id" => "f1", "config_id" => "12"}}
  end

  test "formats error response" do
    assert {:error, message} =
             GetDocument.run(%{provider: "google_drive", document_id: "f1"}, %{
               node_router: ErrorNodeRouter
             })

    assert message == "Data source document request failed: :timeout"
  end
end

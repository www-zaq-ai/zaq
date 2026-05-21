defmodule Zaq.Agent.Tools.UpdateDocumentTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.UpdateDocument
  alias Zaq.Event

  defmodule StubNodeRouter do
    def dispatch(%Event{request: %{provider: "google_drive", params: params}, opts: opts}) do
      send(self(), {:dispatch, opts[:action], params})

      %{
        Event.new(%{}, :channels)
        | response: {:ok, %{status: "updated", record: %{"id" => "f1"}}}
      }
    end
  end

  defmodule ErrorNodeRouter do
    def dispatch(%Event{}), do: %{Event.new(%{}, :channels) | response: {:error, :timeout}}
  end

  defmodule UnexpectedNodeRouter do
    def dispatch(%Event{}), do: %{Event.new(%{}, :channels) | response: :ok}
  end

  test "dispatches datasource update_file action" do
    assert {:ok, %{status: "updated", record: %{"id" => "f1"}}} =
             UpdateDocument.run(
               %{provider: "google_drive", document_id: "f1", name: "Renamed"},
               %{
                 node_router: StubNodeRouter
               }
             )

    assert_received {:dispatch, :data_source_update_file,
                     %{"file_id" => "f1", "name" => "Renamed"}}
  end

  test "passes optional params when present" do
    assert {:ok, _} =
             UpdateDocument.run(
               %{
                 provider: "google_drive",
                 document_id: "f1",
                 content: "hello",
                 path: "/docs",
                 parent_id: "p1",
                 mime_type: "text/plain",
                 config_id: "12"
               },
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_update_file,
                     %{
                       "file_id" => "f1",
                       "content" => "hello",
                       "path" => "/docs",
                       "parent_id" => "p1",
                       "mime_type" => "text/plain",
                       "config_id" => "12"
                     }}
  end

  test "formats datasource error reason" do
    assert {:error, message} =
             UpdateDocument.run(%{provider: "google_drive", document_id: "f1"}, %{
               node_router: ErrorNodeRouter
             })

    assert message == "Data source document update failed: :timeout"
  end

  test "returns unexpected response error" do
    assert {:error, message} =
             UpdateDocument.run(%{provider: "google_drive", document_id: "f1"}, %{
               node_router: UnexpectedNodeRouter
             })

    assert message == "Unexpected data source response: :ok"
  end
end

defmodule Zaq.Agent.Tools.SearchDocumentsTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.SearchDocuments
  alias Zaq.Event

  defmodule StubNodeRouter do
    def dispatch(%Event{request: %{provider: "google_drive", params: params}, opts: opts}) do
      send(self(), {:dispatch, opts[:action], params})

      %{
        Event.new(%{}, :channels)
        | response: {:ok, %{records: [%{"id" => "d1", "name" => "Doc"}]}}
      }
    end
  end

  test "dispatches datasource search_files action and returns metadata records" do
    assert {:ok, %{records: [%{"id" => "d1", "name" => "Doc"}], count: 1}} =
             SearchDocuments.run(%{provider: "google_drive", query: "invoice"}, %{
               node_router: StubNodeRouter
             })

    assert_received {:dispatch, :data_source_search_files, %{"query" => "invoice"}}
  end

  test "passes optional path and config_id" do
    assert {:ok, _} =
             SearchDocuments.run(
               %{provider: "google_drive", query: "invoice", path: "/finance", config_id: "2"},
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_search_files,
                     %{"query" => "invoice", "path" => "/finance", "config_id" => "2"}}
  end
end

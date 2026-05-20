defmodule Zaq.Agent.Tools.ListDocumentsTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.ListDocuments
  alias Zaq.Event

  defmodule StubNodeRouter do
    def dispatch(%Event{request: %{provider: "google_drive", params: params}, opts: opts}) do
      send(self(), {:dispatch, opts[:action], params})

      %{Event.new(%{}, :channels) | response: {:ok, %{records: [%{"id" => "d1"}]}}}
    end
  end

  test "dispatches datasource list_files action and adds count" do
    assert {:ok, %{records: [%{"id" => "d1"}], count: 1}} =
             ListDocuments.run(%{provider: "google_drive", path: "/docs"}, %{
               node_router: StubNodeRouter
             })

    assert_received {:dispatch, :data_source_list_files, %{"path" => "/docs"}}
  end

  test "passes config_id when present" do
    assert {:ok, _} =
             ListDocuments.run(
               %{provider: "google_drive", path: "/docs", config_id: "9"},
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_list_files, %{"path" => "/docs", "config_id" => "9"}}
  end
end

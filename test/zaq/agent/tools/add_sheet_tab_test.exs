defmodule Zaq.Agent.Tools.AddSheetTabTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.AddSheetTab
  alias Zaq.Event

  defmodule StubNodeRouter do
    def dispatch(%Event{request: %{provider: "google_drive", params: params}, opts: opts}) do
      send(self(), {:dispatch, opts[:action], params})

      %{
        Event.new(%{}, :channels)
        | response: {:ok, %{status: "created", record: %{id: "s1", kind: :spreadsheet}}}
      }
    end
  end

  test "dispatches datasource sheet add tab action" do
    assert {:ok, %{status: "created", record: %{id: "s1", kind: :spreadsheet}}} =
             AddSheetTab.run(
               %{provider: "google_drive", spreadsheet_id: "s1", title: "New Tab", index: 2},
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_sheet_add_tab,
                     %{"spreadsheet_id" => "s1", "title" => "New Tab", "index" => 2}}
  end
end

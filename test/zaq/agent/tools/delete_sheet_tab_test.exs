defmodule Zaq.Agent.Tools.DeleteSheetTabTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.DeleteSheetTab
  alias Zaq.Event

  defmodule StubNodeRouter do
    def dispatch(%Event{request: %{provider: "google_drive", params: params}, opts: opts}) do
      send(self(), {:dispatch, opts[:action], params})

      %{
        Event.new(%{}, :channels)
        | response: {:ok, %{status: "deleted", record: %{id: "s1", kind: :spreadsheet}}}
      }
    end
  end

  test "dispatches datasource sheet_delete_tab action" do
    assert {:ok, %{status: "deleted", record: %{id: "s1", kind: :spreadsheet}}} =
             DeleteSheetTab.run(
               %{provider: "google_drive", spreadsheet_id: "s1", sheet_id: "123"},
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_sheet_delete_tab,
                     %{"spreadsheet_id" => "s1", "sheet_id" => "123"}}
  end
end

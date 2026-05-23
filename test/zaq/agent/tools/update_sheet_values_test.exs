defmodule Zaq.Agent.Tools.UpdateSheetValuesTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.UpdateSheetValues
  alias Zaq.Event

  defmodule StubNodeRouter do
    def dispatch(%Event{request: %{provider: "google_drive", params: params}, opts: opts}) do
      send(self(), {:dispatch, opts[:action], params})
      %{Event.new(%{}, :channels) | response: {:ok, %{result: %{updated_cells: 2}}}}
    end
  end

  test "dispatches datasource sheet_update_values action" do
    assert {:ok, %{result: %{updated_cells: 2}}} =
             UpdateSheetValues.run(
               %{
                 provider: "google_drive",
                 spreadsheet_id: "s1",
                 range: "Sheet1!A1:B1",
                 values: [["a", "b"]]
               },
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_sheet_update_values,
                     %{
                       "spreadsheet_id" => "s1",
                       "range" => "Sheet1!A1:B1",
                       "values" => [["a", "b"]]
                     }}
  end
end

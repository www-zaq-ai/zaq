defmodule Zaq.Agent.Tools.GetSheetTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.GetSheet
  alias Zaq.Event

  defmodule StubNodeRouter do
    def dispatch(%Event{request: %{provider: "google_drive", params: params}, opts: opts}) do
      send(self(), {:dispatch, opts[:action], params})

      %{Event.new(%{}, :channels) | response: {:ok, %{record: %{id: "s1", kind: :spreadsheet}}}}
    end
  end

  test "dispatches datasource sheet_get action" do
    assert {:ok, %{record: %{id: "s1", kind: :spreadsheet}}} =
             GetSheet.run(
               %{provider: "google_drive", spreadsheet_id: "s1", range: "Sheet1!A1:B2"},
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_sheet_get,
                     %{"spreadsheet_id" => "s1", "range" => "Sheet1!A1:B2"}}
  end
end

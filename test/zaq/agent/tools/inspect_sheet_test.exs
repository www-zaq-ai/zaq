defmodule Zaq.Agent.Tools.InspectSheetTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.InspectSheet
  alias Zaq.Event

  defmodule StubNodeRouter do
    def dispatch(%Event{request: %{provider: "google_drive", params: params}, opts: opts}) do
      send(self(), {:dispatch, opts[:action], params})

      %{Event.new(%{}, :channels) | response: {:ok, %{record: %{id: "s1", kind: :spreadsheet}}}}
    end
  end

  test "dispatches datasource sheet inspect action" do
    assert {:ok, %{record: %{id: "s1", kind: :spreadsheet}}} =
             InspectSheet.run(
               %{provider: "google_drive", spreadsheet_id: "s1", config_id: "12"},
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_sheet_inspect,
                     %{"spreadsheet_id" => "s1", "config_id" => "12"}}
  end
end

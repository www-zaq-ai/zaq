defmodule Zaq.Agent.Tools.Sheets.GetSheetTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.Sheets.GetSheet
  alias Zaq.Contracts.Record
  alias Zaq.Event

  defmodule StubNodeRouter do
    def dispatch(%Event{request: %{provider: "google_drive", params: params}, opts: opts}) do
      send(self(), {:dispatch, opts[:action], params})

      record = %Record{id: "s1", kind: :spreadsheet}
      %{Event.new(%{}, :channels) | response: {:ok, %{record: record}}}
    end
  end

  defmodule PlainMapRecordRouter do
    def dispatch(%Event{}) do
      %{Event.new(%{}, :channels) | response: {:ok, %{record: %{id: "s1", kind: :spreadsheet}}}}
    end
  end

  test "dispatches datasource sheet_get action" do
    assert {:ok, %{record: %Record{id: "s1", kind: :spreadsheet}}} =
             GetSheet.run(
               %{provider: "google_drive", spreadsheet_id: "s1", range: "Sheet1!A1:B2"},
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_sheet_get,
                     %{"spreadsheet_id" => "s1", "range" => "Sheet1!A1:B2"}}
  end

  test "rejects datasource responses with a plain map record" do
    assert {:error,
            "Data source sheet read failed: expected record to be %Zaq.Contracts.Record{}"} =
             GetSheet.run(
               %{provider: "google_drive", spreadsheet_id: "s1", range: "Sheet1!A1:B2"},
               %{node_router: PlainMapRecordRouter}
             )
  end

  test "output schema rejects a plain map record" do
    assert {:error, _} =
             GetSheet.validate_output(%{record: %{id: "s1", kind: :spreadsheet}})

    assert {:ok, _} = GetSheet.validate_output(%{record: %Record{id: "s1", kind: :spreadsheet}})
  end
end

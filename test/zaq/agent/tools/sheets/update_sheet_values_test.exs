defmodule Zaq.Agent.Tools.Sheets.UpdateSheetValuesTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.Sheets.UpdateSheetValues
  alias Zaq.Contracts.Record
  alias Zaq.Event

  defmodule StubNodeRouter do
    def dispatch(%Event{request: %{provider: "google_drive", params: params}, opts: opts}) do
      send(self(), {:dispatch, opts[:action], params})
      %{Event.new(%{}, :channels) | response: {:ok, %{result: %{updated_cells: 2}}}}
    end
  end

  defmodule RecordNodeRouter do
    def dispatch(%Event{}) do
      record = %Record{id: "s1", kind: :spreadsheet}
      %{Event.new(%{}, :channels) | response: {:ok, %{status: "updated", record: record}}}
    end
  end

  defmodule PlainMapRecordRouter do
    def dispatch(%Event{}) do
      %{Event.new(%{}, :channels) | response: {:ok, %{status: "updated", record: %{id: "s1"}}}}
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

  test "single-cell mode builds the range and wraps the value" do
    assert {:ok, _} =
             UpdateSheetValues.run(
               %{
                 provider: "google_drive",
                 spreadsheet_id: "s1",
                 row: 5,
                 column: "I",
                 value: 3
               },
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_sheet_update_values,
                     %{"range" => "Sheet1!I5", "values" => [[3]]}}
  end

  test "single-cell mode honors a custom sheet_name" do
    assert {:ok, _} =
             UpdateSheetValues.run(
               %{
                 provider: "google_drive",
                 spreadsheet_id: "s1",
                 row: 2,
                 column: "B",
                 sheet_name: "Leads",
                 value: 0
               },
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_sheet_update_values,
                     %{"range" => "Leads!B2", "values" => [[0]]}}
  end

  test "errors when neither range nor row/column is given" do
    assert {:error, "Data source sheet update failed: provide a range, or row and column"} =
             UpdateSheetValues.run(
               %{provider: "google_drive", spreadsheet_id: "s1", value: 1},
               %{node_router: StubNodeRouter}
             )
  end

  test "errors when neither values nor value is given" do
    assert {:error, "Data source sheet update failed: provide values, or a value"} =
             UpdateSheetValues.run(
               %{provider: "google_drive", spreadsheet_id: "s1", range: "Sheet1!A1"},
               %{node_router: StubNodeRouter}
             )
  end

  test "accepts datasource update responses with a Record struct" do
    assert {:ok, %{status: "updated", record: %Record{id: "s1", kind: :spreadsheet}}} =
             UpdateSheetValues.run(
               %{
                 provider: "google_drive",
                 spreadsheet_id: "s1",
                 range: "Sheet1!A1:B1",
                 values: [["a", "b"]]
               },
               %{node_router: RecordNodeRouter}
             )
  end

  test "rejects datasource update responses with a plain map record" do
    assert {:error,
            "Data source sheet update failed: expected record to be %Zaq.Contracts.Record{}"} =
             UpdateSheetValues.run(
               %{
                 provider: "google_drive",
                 spreadsheet_id: "s1",
                 range: "Sheet1!A1:B1",
                 values: [["a", "b"]]
               },
               %{node_router: PlainMapRecordRouter}
             )
  end

  test "output schema rejects a plain map record when one is present" do
    assert {:error, _} =
             UpdateSheetValues.validate_output(%{status: "updated", record: %{id: "s1"}})

    assert {:ok, _} =
             UpdateSheetValues.validate_output(%{
               status: "updated",
               record: %Record{id: "s1", kind: :spreadsheet}
             })
  end
end

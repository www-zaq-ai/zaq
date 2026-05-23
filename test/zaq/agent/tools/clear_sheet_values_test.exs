defmodule Zaq.Agent.Tools.ClearSheetValuesTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.ClearSheetValues
  alias Zaq.Event

  defmodule StubNodeRouterOk do
    def dispatch(%Event{request: %{provider: "google_drive", params: params}, opts: opts}) do
      send(self(), {:dispatch, opts[:action], params})

      %{
        Event.new(%{}, :channels)
        | response: {:ok, %{status: "cleared", record: %{id: "s1", kind: :spreadsheet}}}
      }
    end
  end

  defmodule StubNodeRouterError do
    def dispatch(%Event{}), do: %{Event.new(%{}, :channels) | response: {:error, :timeout}}
  end

  test "run/2 dispatches clear values action with required params only" do
    assert {:ok, %{status: "cleared", record: %{id: "s1", kind: :spreadsheet}}} =
             ClearSheetValues.run(
               %{provider: "google_drive", spreadsheet_id: "s1", range: "Sheet1!A1:C10"},
               %{node_router: StubNodeRouterOk}
             )

    assert_received {:dispatch, :data_source_sheet_clear_values, dispatched_params}

    assert dispatched_params == %{
             "spreadsheet_id" => "s1",
             "range" => "Sheet1!A1:C10"
           }

    refute Map.has_key?(dispatched_params, "config_id")
  end

  test "run/2 includes optional config_id when provided" do
    assert {:ok, %{status: "cleared", record: %{id: "s1", kind: :spreadsheet}}} =
             ClearSheetValues.run(
               %{
                 provider: "google_drive",
                 spreadsheet_id: "s1",
                 range: "Sheet1!A1:C10",
                 config_id: "cfg-123"
               },
               %{node_router: StubNodeRouterOk}
             )

    assert_received {:dispatch, :data_source_sheet_clear_values, dispatched_params}

    assert dispatched_params == %{
             "spreadsheet_id" => "s1",
             "range" => "Sheet1!A1:C10",
             "config_id" => "cfg-123"
           }
  end

  test "run/2 propagates datasource errors with tool-specific prefix" do
    assert {:error, "Data source sheet clear failed: :timeout"} =
             ClearSheetValues.run(
               %{provider: "google_drive", spreadsheet_id: "s1", range: "Sheet1!A1:C10"},
               %{node_router: StubNodeRouterError}
             )
  end
end

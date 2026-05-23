defmodule Zaq.Agent.Tools.AppendSheetValuesTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.AppendSheetValues
  alias Zaq.Event

  defmodule StubNodeRouter do
    def dispatch(%Event{request: %{provider: "google_drive", params: params}, opts: opts}) do
      send(self(), {:dispatch, opts[:action], params})

      %{
        Event.new(%{}, :channels)
        | response: {:ok, %{status: "appended", result: %{updated_rows: 1}}}
      }
    end
  end

  defmodule ErrorNodeRouter do
    def dispatch(%Event{}), do: %{Event.new(%{}, :channels) | response: {:error, :timeout}}
  end

  defp base_params do
    %{
      provider: "google_drive",
      spreadsheet_id: "sheet-123",
      range: "Sheet1!A:C",
      values: [["a", "b", "c"]]
    }
  end

  test "dispatches datasource sheet_append_values action with required params only" do
    assert {:ok, %{status: "appended", result: %{updated_rows: 1}}} =
             AppendSheetValues.run(base_params(), %{node_router: StubNodeRouter})

    assert_received {:dispatch, :data_source_sheet_append_values, params}

    assert %{
             "spreadsheet_id" => "sheet-123",
             "range" => "Sheet1!A:C",
             "values" => [["a", "b", "c"]]
           } = params

    refute Map.has_key?(params, "value_input_option")
    refute Map.has_key?(params, "config_id")
  end

  test "includes value_input_option and config_id when provided" do
    params = Map.merge(base_params(), %{value_input_option: "USER_ENTERED", config_id: "cfg-1"})

    assert {:ok, %{status: "appended", result: %{updated_rows: 1}}} =
             AppendSheetValues.run(params, %{node_router: StubNodeRouter})

    assert_received {:dispatch, :data_source_sheet_append_values,
                     %{
                       "spreadsheet_id" => "sheet-123",
                       "range" => "Sheet1!A:C",
                       "values" => [["a", "b", "c"]],
                       "value_input_option" => "USER_ENTERED",
                       "config_id" => "cfg-1"
                     }}
  end

  test "returns prefixed error when datasource append fails" do
    assert {:error, message} =
             AppendSheetValues.run(base_params(), %{node_router: ErrorNodeRouter})

    assert message =~ "Data source sheet append failed:"
    assert message =~ "timeout"
  end
end

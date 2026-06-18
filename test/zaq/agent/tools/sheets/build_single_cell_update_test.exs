defmodule Zaq.Agent.Tools.Sheets.BuildSingleCellUpdateTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.Sheets.BuildSingleCellUpdate

  describe "run/2" do
    test "builds a single-cell range and matrix" do
      assert {:ok, %{range: "Sheet1!I5", values: [[3]]}} =
               BuildSingleCellUpdate.run(
                 %{row_index: 5, value: 2, column: "I", increment_by: 1},
                 %{}
               )
    end

    test "accepts string row and value inputs from workflow cascades" do
      assert {:ok, %{range: "Leads!F10", values: [[6]]}} =
               BuildSingleCellUpdate.run(
                 %{
                   row_index: "10",
                   value: "5",
                   column: "F",
                   sheet_name: "Leads",
                   increment_by: 1
                 },
                 %{}
               )
    end

    test "defaults nil value to zero" do
      assert {:ok, %{values: [[1]]}} =
               BuildSingleCellUpdate.run(%{row_index: 3, value: nil, increment_by: 1}, %{})
    end

    test "rejects invalid row_index" do
      assert {:error, "invalid_row_index"} =
               BuildSingleCellUpdate.run(%{row_index: "bad", value: 1}, %{})
    end

    test "rejects non-positive row_index" do
      assert {:error, "row_index_must_be_positive"} =
               BuildSingleCellUpdate.run(%{row_index: 0, value: 1}, %{})
    end
  end
end

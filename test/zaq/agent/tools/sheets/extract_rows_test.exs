defmodule Zaq.Agent.Tools.Sheets.ExtractRowsTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.Sheets.ExtractRows
  alias Zaq.Contracts.Record

  @ctx %{}

  defp record(content),
    do: %Record{id: "sheet-1", kind: :spreadsheet, content: content}

  describe "run/2 — list-of-lists content (header_row default)" do
    test "converts headers + data rows to maps with downcased keys" do
      rec = record([["Name", "Email"], ["Alice", "alice@example.com"]])

      assert {:ok, %{rows: [row]}} = ExtractRows.run(%{record: rec}, @ctx)
      assert row["name"] == "Alice"
      assert row["email"] == "alice@example.com"
    end

    test "assigns row_index starting at 2 (header = row 1)" do
      rec = record([["Name"], ["Alice"], ["Bob"]])

      assert {:ok, %{rows: rows}} = ExtractRows.run(%{record: rec}, @ctx)
      assert Enum.map(rows, & &1["row_index"]) == [2, 3]
    end

    test "normalizes TRUE/FALSE strings to booleans" do
      rec = record([["active", "flagged"], ["TRUE", "FALSE"]])

      assert {:ok, %{rows: [row]}} = ExtractRows.run(%{record: rec}, @ctx)
      assert row["active"] == true
      assert row["flagged"] == false
    end

    test "normalizes lowercase true/false strings to booleans" do
      rec = record([["active"], ["true"]])

      assert {:ok, %{rows: [row]}} = ExtractRows.run(%{record: rec}, @ctx)
      assert row["active"] == true
    end

    test "casts numeric strings to integers" do
      rec = record([["email_state"], ["3"]])

      assert {:ok, %{rows: [row]}} = ExtractRows.run(%{record: rec}, @ctx)
      assert row["email_state"] == 3
    end

    test "leaves non-numeric strings as-is" do
      rec = record([["name"], ["Alice123"]])

      assert {:ok, %{rows: [row]}} = ExtractRows.run(%{record: rec}, @ctx)
      assert row["name"] == "Alice123"
    end

    test "downcases column headers" do
      rec = record([["First_Name", "EMAIL_STATE"], ["Alice", "2"]])

      assert {:ok, %{rows: [row]}} = ExtractRows.run(%{record: rec}, @ctx)
      assert Map.has_key?(row, "first_name")
      assert Map.has_key?(row, "email_state")
    end
  end

  describe "run/2 — list-of-maps content (header_row default)" do
    test "drops header row and normalizes remaining maps" do
      rec = record([%{"name" => "header"}, %{"name" => "Alice", "active" => "TRUE"}])

      assert {:ok, %{rows: [row]}} = ExtractRows.run(%{record: rec}, @ctx)
      assert row["name"] == "Alice"
      assert row["active"] == true
    end

    test "assigns row_index starting at 2" do
      rec = record([%{"x" => "h"}, %{"x" => "a"}, %{"x" => "b"}])

      assert {:ok, %{rows: rows}} = ExtractRows.run(%{record: rec}, @ctx)
      assert Enum.map(rows, & &1["row_index"]) == [2, 3]
    end

    test "raises when map-style content contains a scalar data row" do
      rec = record([%{"header" => "row"}, "raw value"])

      assert_raise Protocol.UndefinedError, fn ->
        ExtractRows.run(%{record: rec}, @ctx)
      end
    end
  end

  describe "run/2 — header_row: false" do
    test "keys list rows positionally and keeps the first row, row_index from 1" do
      rec = record([["Alice", "TRUE"], ["Bob", "FALSE"]])

      assert {:ok, %{rows: rows}} = ExtractRows.run(%{record: rec, header_row: false}, @ctx)
      assert Enum.map(rows, & &1["row_index"]) == [1, 2]
      assert [%{"0" => "Alice", "1" => true} | _] = rows
    end

    test "keeps all map rows (does not drop the first) with row_index from 1" do
      rec = record([%{"name" => "Alice"}, %{"name" => "Bob"}])

      assert {:ok, %{rows: rows}} = ExtractRows.run(%{record: rec, header_row: false}, @ctx)
      assert Enum.map(rows, & &1["name"]) == ["Alice", "Bob"]
      assert Enum.map(rows, & &1["row_index"]) == [1, 2]
    end

    test "preserves already typed scalar values" do
      rec = record([%{active: false, archived: "false", score: 7, ratio: 1.5}])

      assert {:ok, %{rows: [row]}} = ExtractRows.run(%{record: rec, header_row: false}, @ctx)
      assert row["active"] == false
      assert row["archived"] == false
      assert row["score"] == 7
      assert row["ratio"] == 1.5
      assert row["row_index"] == 1
    end
  end

  describe "run/2 — input contract" do
    test "rejects a plain map (not a %Record{})" do
      assert {:error, {:invalid_input, :expected_record}} =
               ExtractRows.run(%{record: %{content: [["name"], ["Alice"]]}}, @ctx)
    end

    test "rejects a string-keyed map" do
      assert {:error, {:invalid_input, :expected_record}} =
               ExtractRows.run(%{record: %{"content" => [["name"], ["Alice"]]}}, @ctx)
    end

    test "rejects a list" do
      assert {:error, {:invalid_input, :expected_record}} =
               ExtractRows.run(%{record: [["name"], ["Alice"]]}, @ctx)
    end
  end

  describe "run/2 — edge cases" do
    test "returns empty rows for nil content" do
      assert {:ok, %{rows: []}} = ExtractRows.run(%{record: record(nil)}, @ctx)
    end

    test "returns empty rows for empty content list" do
      assert {:ok, %{rows: []}} = ExtractRows.run(%{record: record([])}, @ctx)
    end
  end
end

defmodule Zaq.Agent.Tools.GoogleSheets.ExtractRowsTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.GoogleSheets.ExtractRows

  @ctx %{}

  describe "run/2 — list-of-lists content" do
    test "converts headers + data rows to maps with downcased keys" do
      record = %{content: [["Name", "Email"], ["Alice", "alice@example.com"]]}

      assert {:ok, %{rows: [row]}} = ExtractRows.run(%{record: record}, @ctx)
      assert row["name"] == "Alice"
      assert row["email"] == "alice@example.com"
    end

    test "assigns row_index starting at 2 (header = row 1)" do
      record = %{content: [["Name"], ["Alice"], ["Bob"]]}

      assert {:ok, %{rows: rows}} = ExtractRows.run(%{record: record}, @ctx)
      assert Enum.map(rows, & &1["row_index"]) == [2, 3]
    end

    test "normalizes TRUE/FALSE strings to booleans" do
      record = %{content: [["active", "flagged"], ["TRUE", "FALSE"]]}

      assert {:ok, %{rows: [row]}} = ExtractRows.run(%{record: record}, @ctx)
      assert row["active"] == true
      assert row["flagged"] == false
    end

    test "normalizes lowercase true/false strings to booleans" do
      record = %{content: [["active"], ["true"]]}

      assert {:ok, %{rows: [row]}} = ExtractRows.run(%{record: record}, @ctx)
      assert row["active"] == true
    end

    test "casts numeric strings to integers" do
      record = %{content: [["email_state"], ["3"]]}

      assert {:ok, %{rows: [row]}} = ExtractRows.run(%{record: record}, @ctx)
      assert row["email_state"] == 3
    end

    test "leaves non-numeric strings as-is" do
      record = %{content: [["name"], ["Alice123"]]}

      assert {:ok, %{rows: [row]}} = ExtractRows.run(%{record: record}, @ctx)
      assert row["name"] == "Alice123"
    end

    test "downcases column headers" do
      record = %{content: [["First_Name", "EMAIL_STATE"], ["Alice", "2"]]}

      assert {:ok, %{rows: [row]}} = ExtractRows.run(%{record: record}, @ctx)
      assert Map.has_key?(row, "first_name")
      assert Map.has_key?(row, "email_state")
    end

    test "accepts string-keyed record" do
      record = %{"content" => [["name"], ["Alice"]]}

      assert {:ok, %{rows: [row]}} = ExtractRows.run(%{record: record}, @ctx)
      assert row["name"] == "Alice"
    end
  end

  describe "run/2 — list-of-maps content" do
    test "drops header row and normalizes remaining maps" do
      record = %{content: [%{"name" => "header"}, %{"name" => "Alice", "active" => "TRUE"}]}

      assert {:ok, %{rows: [row]}} = ExtractRows.run(%{record: record}, @ctx)
      assert row["name"] == "Alice"
      assert row["active"] == true
    end

    test "assigns row_index starting at 2" do
      record = %{content: [%{"x" => "h"}, %{"x" => "a"}, %{"x" => "b"}]}

      assert {:ok, %{rows: rows}} = ExtractRows.run(%{record: record}, @ctx)
      assert Enum.map(rows, & &1["row_index"]) == [2, 3]
    end
  end

  describe "run/2 — edge cases" do
    test "returns empty rows for nil content" do
      record = %{content: nil}

      assert {:ok, %{rows: []}} = ExtractRows.run(%{record: record}, @ctx)
    end

    test "returns empty rows for empty content list" do
      record = %{content: []}

      assert {:ok, %{rows: []}} = ExtractRows.run(%{record: record}, @ctx)
    end
  end
end

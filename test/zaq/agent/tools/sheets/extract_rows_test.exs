defmodule Zaq.Agent.Tools.Sheets.ExtractRowsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Agent.Tools.Sheets.ExtractRows
  alias Zaq.Contracts.Record

  @ctx %{}

  defp record(content),
    do: %Record{id: "sheet-1", kind: :spreadsheet, content: content}

  describe "run/2 — list-of-lists content (header_row default)" do
    test "converts headers + data rows to maps with downcased keys" do
      rec = record([["Name", "Email"], ["Alice", "alice@example.com"]])

      assert {:ok, %{rows: [row], metadata: metadata}} = ExtractRows.run(%{record: rec}, @ctx)
      assert row["name"] == "Alice"
      assert row["email"] == "alice@example.com"

      assert metadata.headers_detected == true
      assert metadata.headers["name"] == %{column: "A", original: "Name"}
      assert metadata.headers["email"] == %{column: "B", original: "Email"}
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

    test "uses column letters for empty header values" do
      rec = record([["", nil, "Name"], ["value-a", "value-b", "Alice"]])

      assert {:ok, %{rows: [row], metadata: metadata}} = ExtractRows.run(%{record: rec}, @ctx)

      assert row["A"] == "value-a"
      assert row["B"] == "value-b"
      assert row["name"] == "Alice"

      assert metadata.headers["A"] == %{column: "A", original: ""}
      assert metadata.headers["B"] == %{column: "B", original: nil}
      assert metadata.headers["name"] == %{column: "C", original: "Name"}
    end

    test "maps extracted headers to spreadsheet columns beyond Z" do
      headers = Enum.map(1..27, &"Header#{&1}")
      rec = record([headers, Enum.map(1..27, &"value-#{&1}")])

      assert {:ok, %{metadata: metadata}} = ExtractRows.run(%{record: rec}, @ctx)

      assert metadata.headers["header26"].column == "Z"
      assert metadata.headers["header27"].column == "AA"
    end

    test "keeps trailing header columns as empty strings when row cells are missing" do
      rec = record([["A", "B", "C", "D"], ["value-a", "value-b"]])

      assert {:ok, %{rows: [row]}} = ExtractRows.run(%{record: rec}, @ctx)
      assert row == %{"a" => "value-a", "b" => "value-b", "c" => "", "d" => "", "row_index" => 2}
    end

    property "list rows preserve every header key even when rows are shorter" do
      check all(
              header_count <- StreamData.integer(1..20),
              values <-
                StreamData.list_of(StreamData.string(:alphanumeric, max_length: 8),
                  max_length: 20
                )
            ) do
        headers = Enum.map(1..header_count, &"Header#{&1}")
        row_values = Enum.take(values, header_count)
        rec = record([headers, row_values])

        assert {:ok, %{rows: [row], metadata: metadata}} = ExtractRows.run(%{record: rec}, @ctx)

        expected_keys = Enum.map(headers, &String.downcase/1)
        assert Enum.all?(expected_keys, &Map.has_key?(row, &1))
        assert metadata.headers_detected == true

        expected_keys
        |> Enum.with_index()
        |> Enum.each(fn {key, index} ->
          assert metadata.headers[key].column == column_letter(index)
        end)

        if length(row_values) < header_count do
          (length(row_values) + 1)..header_count
          |> Enum.each(fn index ->
            assert row["header#{index}"] == ""
          end)
        end
      end
    end
  end

  describe "run/2 — list-of-maps content (header_row default)" do
    test "drops header row and normalizes remaining maps" do
      rec = record([%{"name" => "header"}, %{"name" => "Alice", "active" => "TRUE"}])

      assert {:ok, %{rows: [row], metadata: metadata}} = ExtractRows.run(%{record: rec}, @ctx)
      assert row["name"] == "Alice"
      assert row["active"] == true
      assert metadata == %{headers_detected: false, headers: %{}}
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
    test "keys list rows by column letter and keeps the first row, row_index from 1" do
      rec = record([["Alice", "TRUE"], ["Bob", "FALSE"]])

      assert {:ok, %{rows: rows, metadata: metadata}} =
               ExtractRows.run(%{record: rec, header_row: false}, @ctx)

      assert Enum.map(rows, & &1["row_index"]) == [1, 2]
      assert [%{"A" => "Alice", "B" => true} | _] = rows
      assert metadata == %{headers_detected: false, headers: %{}}
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

  defp column_letter(index), do: do_column_letter(index + 1, "")

  defp do_column_letter(0, acc), do: acc

  defp do_column_letter(index, acc) do
    remainder = rem(index - 1, 26)
    do_column_letter(div(index - 1, 26), <<?A + remainder>> <> acc)
  end
end

defmodule Zaq.Engine.Workflows.Conditions.FieldComparisonTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Workflows.Conditions.{ConditionNotMet, FieldComparison}

  describe "run/2 — field resolution" do
    test "resolves field via atom key when atom exists in atom table" do
      params = %{field: "status", op: "eq", value: "active", status: "active"}

      assert {:ok, %{passed: true, field: "status", actual: "active"}, _} =
               FieldComparison.run(params, %{})
    end

    test "resolves field via string key when field name is not an existing atom" do
      unique_field = "zaq_never_atom_#{System.unique_integer([:positive])}"
      params = %{field: unique_field, op: "eq", value: "hello"} |> Map.put(unique_field, "hello")

      assert {:ok, %{passed: true}, _} = FieldComparison.run(params, %{})
    end

    test "resolves field via string key when params carry only string keys" do
      params = %{"score" => 10, field: "score", op: "gt", value: 5}

      assert {:ok, %{passed: true, actual: 10}, _} = FieldComparison.run(params, %{})
    end

    test "atom key takes precedence over string key when both present" do
      params = %{
        "status" => "string_value",
        field: "status",
        op: "eq",
        value: "atom_value",
        status: "atom_value"
      }

      assert {:ok, %{passed: true, actual: "atom_value"}, _} = FieldComparison.run(params, %{})
    end

    test "field absent from params evaluates actual as nil" do
      params = %{field: "missing", op: "empty", value: nil}

      assert {:ok, %{passed: true, actual: nil}, _} = FieldComparison.run(params, %{})
    end
  end

  describe "run/2 — comparison operators" do
    test "eq passes when values match" do
      assert {:ok, %{passed: true}, _} = run("name", "eq", "alice", name: "alice")
    end

    test "neq passes when values differ" do
      assert {:ok, %{passed: true}, _} = run("name", "neq", "bob", name: "alice")
    end

    test "gt passes when actual is greater" do
      assert {:ok, %{passed: true}, _} = run("score", "gt", 5, score: 10)
    end

    test "lt passes when actual is less" do
      assert {:ok, %{passed: true}, _} = run("score", "lt", 10, score: 5)
    end

    test "gte passes when actual equals threshold" do
      assert {:ok, %{passed: true}, _} = run("score", "gte", 5, score: 5)
    end

    test "lte passes when actual is below threshold" do
      assert {:ok, %{passed: true}, _} = run("score", "lte", 10, score: 7)
    end

    test "not_empty passes when value is a non-empty string" do
      assert {:ok, %{passed: true}, _} = run("name", "not_empty", nil, name: "alice")
    end

    test "empty passes when value is nil" do
      assert {:ok, %{passed: true}, _} = run("name", "empty", nil, name: nil)
    end

    test "in passes when actual is contained in the value list" do
      assert {:ok, %{passed: true}, _} = run("role", "in", ["admin", "owner"], role: "admin")
    end

    test "raises ConditionNotMet when condition fails" do
      assert_raise ConditionNotMet, fn ->
        run("status", "eq", "active", status: "inactive")
      end
    end
  end

  defp run(field, op, value, extra) do
    params = Map.merge(%{field: field, op: op, value: value}, Map.new(extra))
    FieldComparison.run(params, %{})
  end
end

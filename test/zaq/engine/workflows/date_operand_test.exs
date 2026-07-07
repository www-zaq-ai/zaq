defmodule Zaq.Engine.Workflows.DateOperandTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Workflows.DateOperand

  # Fixed clock injected via opts[:now] — async-safe, no global state.
  @now ~U[2026-07-06 15:30:00Z]
  @opts [now: @now]

  describe "resolve_expected/3 — ISO8601 strings" do
    test "parses a date string for type date" do
      assert {:ok, ~D[2026-07-06]} = DateOperand.resolve_expected("2026-07-06", "date", @opts)
    end

    test "parses a datetime string for type datetime" do
      assert {:ok, dt} = DateOperand.resolve_expected("2026-07-06T10:00:00Z", "datetime", @opts)
      assert DateTime.compare(dt, ~U[2026-07-06 10:00:00Z]) == :eq
    end

    test "truncates a datetime string to a date for type date" do
      assert {:ok, ~D[2026-07-06]} =
               DateOperand.resolve_expected("2026-07-06T23:59:00Z", "date", @opts)
    end

    test "interprets a bare date string as midnight UTC for type datetime" do
      assert {:ok, dt} = DateOperand.resolve_expected("2026-07-06", "datetime", @opts)
      assert DateTime.compare(dt, ~U[2026-07-06 00:00:00Z]) == :eq
    end

    test "returns :error for garbage strings" do
      assert :error = DateOperand.resolve_expected("not-a-date", "date", @opts)
      assert :error = DateOperand.resolve_expected("2026-13-45", "datetime", @opts)
    end
  end

  describe "resolve_expected/3 — sentinels" do
    test "today resolves to the clock's calendar day (date)" do
      assert {:ok, ~D[2026-07-06]} = DateOperand.resolve_expected("today", "date", @opts)
    end

    test "today resolves to midnight of the clock day (datetime)" do
      assert {:ok, dt} = DateOperand.resolve_expected("today", "datetime", @opts)
      assert DateTime.compare(dt, ~U[2026-07-06 00:00:00Z]) == :eq
    end

    test "now resolves to the exact clock instant (datetime)" do
      assert {:ok, @now} = DateOperand.resolve_expected("now", "datetime", @opts)
    end

    test "now truncates to the clock day (date)" do
      assert {:ok, ~D[2026-07-06]} = DateOperand.resolve_expected("now", "date", @opts)
    end
  end

  describe "resolve_expected/3 — relative maps" do
    test "negative days off today (older than 7 days)" do
      assert {:ok, ~D[2026-06-29]} =
               DateOperand.resolve_expected(%{"from" => "today", "days" => -7}, "date", @opts)
    end

    test "positive days off today" do
      assert {:ok, ~D[2026-07-09]} =
               DateOperand.resolve_expected(%{"from" => "today", "days" => 3}, "date", @opts)
    end

    test "hours off now (datetime)" do
      assert {:ok, dt} =
               DateOperand.resolve_expected(%{"from" => "now", "hours" => -2}, "datetime", @opts)

      assert DateTime.compare(dt, ~U[2026-07-06 13:30:00Z]) == :eq
    end

    test "minutes off now (datetime)" do
      assert {:ok, dt} =
               DateOperand.resolve_expected(
                 %{"from" => "now", "minutes" => 15},
                 "datetime",
                 @opts
               )

      assert DateTime.compare(dt, ~U[2026-07-06 15:45:00Z]) == :eq
    end

    test "accepts atom keys (in-memory maps)" do
      assert {:ok, ~D[2026-06-29]} =
               DateOperand.resolve_expected(%{from: "today", days: -7}, "date", @opts)
    end

    test "returns :error for an unknown from base" do
      assert :error =
               DateOperand.resolve_expected(%{"from" => "bogus", "days" => 1}, "date", @opts)
    end

    test "returns :error for a non-integer offset" do
      assert :error =
               DateOperand.resolve_expected(
                 %{"from" => "today", "days" => "seven"},
                 "date",
                 @opts
               )
    end
  end

  describe "resolve_expected/3 — invalid type / value" do
    test "returns :error for an unknown type" do
      assert :error = DateOperand.resolve_expected("2026-07-06", "instant", @opts)
    end

    test "returns :error for a non-string, non-map value" do
      assert :error = DateOperand.resolve_expected(12_345, "date", @opts)
    end
  end

  describe "resolve_expected/3 — default clock" do
    test "falls back to the real clock when no :now is supplied" do
      assert {:ok, %Date{} = today} = DateOperand.resolve_expected("today", "date")
      assert Date.compare(today, DateTime.to_date(DateTime.utc_now())) == :eq
    end
  end

  describe "coerce_actual/2" do
    test "passes through a Date for type date" do
      assert {:ok, ~D[2026-07-06]} = DateOperand.coerce_actual(~D[2026-07-06], "date")
    end

    test "truncates a DateTime to a Date for type date" do
      assert {:ok, ~D[2026-07-06]} = DateOperand.coerce_actual(~U[2026-07-06 10:00:00Z], "date")
    end

    test "truncates a NaiveDateTime to a Date for type date" do
      assert {:ok, ~D[2026-07-06]} = DateOperand.coerce_actual(~N[2026-07-06 10:00:00], "date")
    end

    test "parses an ISO string for type date" do
      assert {:ok, ~D[2026-07-06]} = DateOperand.coerce_actual("2026-07-06", "date")
      assert {:ok, ~D[2026-07-06]} = DateOperand.coerce_actual("2026-07-06T09:00:00Z", "date")
    end

    test "passes through a DateTime for type datetime" do
      assert {:ok, dt} = DateOperand.coerce_actual(~U[2026-07-06 10:00:00Z], "datetime")
      assert DateTime.compare(dt, ~U[2026-07-06 10:00:00Z]) == :eq
    end

    test "lifts a NaiveDateTime to UTC for type datetime" do
      assert {:ok, dt} = DateOperand.coerce_actual(~N[2026-07-06 10:00:00], "datetime")
      assert DateTime.compare(dt, ~U[2026-07-06 10:00:00Z]) == :eq
    end

    test "lifts a Date to midnight UTC for type datetime" do
      assert {:ok, dt} = DateOperand.coerce_actual(~D[2026-07-06], "datetime")
      assert DateTime.compare(dt, ~U[2026-07-06 00:00:00Z]) == :eq
    end

    test "returns :error for garbage and unknown type" do
      assert :error = DateOperand.coerce_actual("nope", "date")
      assert :error = DateOperand.coerce_actual(:atom, "datetime")
      assert :error = DateOperand.coerce_actual(~D[2026-07-06], "instant")
    end
  end

  describe "property: totality" do
    property "resolve_expected never raises for arbitrary terms" do
      check all(
              value <-
                one_of([
                  string(:printable),
                  integer(),
                  constant(nil),
                  constant(%{"from" => "today", "days" => -1}),
                  map_of(string(:alphanumeric), integer())
                ]),
              type <- member_of(["date", "datetime", "bogus"])
            ) do
        result = DateOperand.resolve_expected(value, type, @opts)

        assert result == :error or match?({:ok, %Date{}}, result) or
                 match?({:ok, %DateTime{}}, result)
      end
    end

    property "coerce_actual never raises for arbitrary terms" do
      check all(
              value <-
                one_of([
                  string(:printable),
                  integer(),
                  constant(nil),
                  constant(~D[2026-07-06]),
                  constant(~U[2026-07-06 10:00:00Z])
                ]),
              type <- member_of(["date", "datetime", "bogus"])
            ) do
        result = DateOperand.coerce_actual(value, type)

        assert result == :error or match?({:ok, %Date{}}, result) or
                 match?({:ok, %DateTime{}}, result)
      end
    end
  end
end

defmodule Zaq.Engine.Workflows.EdgeConditionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Workflows.EdgeCondition

  # Fixed clock injected via opts[:now] — async-safe, resolves sentinels/relative maps.
  @now ~U[2026-07-06 15:30:00Z]

  describe "ops/0" do
    test "returns the full operator vocabulary" do
      ops = EdgeCondition.ops()
      assert :eq in ops
      assert :neq in ops
      assert :gt in ops
      assert :lt in ops
      assert :gte in ops
      assert :lte in ops
      assert :not_empty in ops
      assert :empty in ops
      assert :in in ops
    end
  end

  describe "changeset/1" do
    test "accepts string-keyed condition maps" do
      changeset = EdgeCondition.changeset(%{"field" => "count", "op" => "gt", "value" => 0})

      assert changeset.valid?
      assert changeset.changes.field == "count"
      assert changeset.changes.op == "gt"
      assert changeset.changes.value == 0
    end

    test "accepts atom-keyed maps and atom operators" do
      changeset = EdgeCondition.changeset(%{field: "count", op: :eq, value: 1})

      assert changeset.valid?
      assert changeset.changes.field == "count"
      assert changeset.changes.op == "eq"
      assert changeset.changes.value == 1
    end

    test "rejects missing required fields" do
      changeset = EdgeCondition.changeset(%{})

      refute changeset.valid?
      assert {:field, {"can't be blank", [validation: :required]}} in changeset.errors
      assert {:op, {"can't be blank", [validation: :required]}} in changeset.errors
    end

    test "rejects blank fields and unknown operators" do
      changeset = EdgeCondition.changeset(%{"field" => "", "op" => "bogus"})

      refute changeset.valid?
      assert {:field, {"can't be blank", [validation: :required]}} in changeset.errors
      assert {:op, {"is invalid", _}} = List.keyfind(changeset.errors, :op, 0)
    end

    test "requires a list value for in conditions" do
      assert EdgeCondition.changeset(%{"field" => "status", "op" => "in", "value" => ["open"]}).valid?

      changeset = EdgeCondition.changeset(%{"field" => "status", "op" => "in", "value" => "open"})

      refute changeset.valid?
      assert {:value, {"must be a list when op is in", []}} in changeset.errors
    end
  end

  describe "evaluate/3 — :eq" do
    test "returns true when equal" do
      assert EdgeCondition.evaluate(:eq, "male", "male")
      assert EdgeCondition.evaluate(:eq, 1, 1)
      assert EdgeCondition.evaluate(:eq, nil, nil)
    end

    test "returns false when not equal" do
      refute EdgeCondition.evaluate(:eq, "male", "female")
      refute EdgeCondition.evaluate(:eq, 1, 2)
    end
  end

  describe "evaluate/3 — :neq" do
    test "returns true when not equal" do
      assert EdgeCondition.evaluate(:neq, "male", "female")
      assert EdgeCondition.evaluate(:neq, 1, 2)
    end

    test "returns false when equal" do
      refute EdgeCondition.evaluate(:neq, "x", "x")
    end
  end

  describe "evaluate/3 — :gt / :lt / :gte / :lte" do
    test ":gt" do
      assert EdgeCondition.evaluate(:gt, 5, 3)
      refute EdgeCondition.evaluate(:gt, 3, 5)
      refute EdgeCondition.evaluate(:gt, 3, 3)
    end

    test ":lt" do
      assert EdgeCondition.evaluate(:lt, 2, 4)
      refute EdgeCondition.evaluate(:lt, 4, 2)
      refute EdgeCondition.evaluate(:lt, 2, 2)
    end

    test ":gte" do
      assert EdgeCondition.evaluate(:gte, 5, 5)
      assert EdgeCondition.evaluate(:gte, 6, 5)
      refute EdgeCondition.evaluate(:gte, 4, 5)
    end

    test ":lte" do
      assert EdgeCondition.evaluate(:lte, 3, 3)
      assert EdgeCondition.evaluate(:lte, 2, 3)
      refute EdgeCondition.evaluate(:lte, 4, 3)
    end
  end

  describe "evaluate/3 — :not_empty / :empty" do
    test ":empty returns true for nil, empty string, empty list, empty map" do
      assert EdgeCondition.evaluate(:empty, nil, nil)
      assert EdgeCondition.evaluate(:empty, "", nil)
      assert EdgeCondition.evaluate(:empty, "   ", nil)
      assert EdgeCondition.evaluate(:empty, [], nil)
      assert EdgeCondition.evaluate(:empty, %{}, nil)
    end

    test ":empty returns false for non-empty values" do
      refute EdgeCondition.evaluate(:empty, "x", nil)
      refute EdgeCondition.evaluate(:empty, [1], nil)
      refute EdgeCondition.evaluate(:empty, %{a: 1}, nil)
      refute EdgeCondition.evaluate(:empty, 0, nil)
    end

    test ":not_empty is the inverse of :empty" do
      assert EdgeCondition.evaluate(:not_empty, "x", nil)
      assert EdgeCondition.evaluate(:not_empty, [1], nil)
      refute EdgeCondition.evaluate(:not_empty, nil, nil)
      refute EdgeCondition.evaluate(:not_empty, "", nil)
      refute EdgeCondition.evaluate(:not_empty, "   ", nil)
    end

    test "a struct (e.g. %Record{}) is treated as present, not an empty collection" do
      # Regression: a struct passes `is_map/1` but does not implement Enumerable, so
      # `Enum.empty?/1` raised — silently failing the (hidden) edge step and pruning
      # the rest of the DAG. A struct is a present value: not_empty ⇒ true.
      record = struct!(Zaq.Contracts.Record, %{id: "1", kind: :spreadsheet})

      assert EdgeCondition.evaluate(:not_empty, record, nil)
      refute EdgeCondition.evaluate(:empty, record, nil)
    end

    test "runtime_empty?/1 honors Ecto's function-based empty values" do
      assert EdgeCondition.runtime_empty?([])
      assert EdgeCondition.runtime_empty?("   ")
      refute EdgeCondition.runtime_empty?("value")
    end
  end

  describe "evaluate/3 — :in" do
    test "returns true when actual is in expected list" do
      assert EdgeCondition.evaluate(:in, "male", ["male", "female"])
      assert EdgeCondition.evaluate(:in, 3, [1, 2, 3])
    end

    test "returns false when actual is not in expected list" do
      refute EdgeCondition.evaluate(:in, "other", ["male", "female"])
    end

    test "raises ArgumentError when expected is not a list" do
      assert_raise ArgumentError, ~r/invalid edge condition/, fn ->
        EdgeCondition.evaluate(:in, "x", "not_a_list")
      end
    end
  end

  describe "evaluate/3 — unknown op" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/invalid edge condition/, fn ->
        EdgeCondition.evaluate(:bogus_op, "x", "y")
      end
    end
  end

  # Property test: total function for all valid ops; never raises for valid ops.
  describe "evaluate/3 — property: total for valid ops" do
    property "never raises for valid ops with arbitrary comparable values" do
      check all(
              op <- member_of([:eq, :neq, :gt, :lt, :gte, :lte]),
              a <- one_of([integer(), float(), string(:alphanumeric), constant(nil)]),
              b <- one_of([integer(), float(), string(:alphanumeric), constant(nil)])
            ) do
        result = EdgeCondition.evaluate(op, a, b)
        assert is_boolean(result)
      end
    end

    property ":in always returns boolean when expected is a list" do
      check all(
              actual <- one_of([integer(), string(:alphanumeric), constant(nil)]),
              expected <- list_of(one_of([integer(), string(:alphanumeric), constant(nil)]))
            ) do
        result = EdgeCondition.evaluate(:in, actual, expected)
        assert is_boolean(result)
      end
    end

    property ":empty and :not_empty always return boolean" do
      check all(
              val <-
                one_of([
                  integer(),
                  string(:alphanumeric),
                  constant(nil),
                  constant([]),
                  constant(%{})
                ])
            ) do
        assert is_boolean(EdgeCondition.evaluate(:empty, val, nil))
        assert is_boolean(EdgeCondition.evaluate(:not_empty, val, nil))
      end
    end

    property "unknown op always raises ArgumentError" do
      known = MapSet.new(EdgeCondition.ops())

      check all(
              op <-
                atom(:alphanumeric)
                |> filter(&(not MapSet.member?(known, &1)))
                |> filter(&(&1 != :""))
            ) do
        assert_raise ArgumentError, fn ->
          EdgeCondition.evaluate(op, "x", "y")
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Date conditions — an optional `type` ("date"/"datetime") switches comparison
  # ops from `Kernel` term order to chronological `Date`/`DateTime.compare/2`.
  # ---------------------------------------------------------------------------
  describe "changeset/1 — date type" do
    test "accepts a valid type with a resolvable value" do
      assert EdgeCondition.changeset(%{
               "field" => "due_date",
               "op" => "lt",
               "value" => "today",
               "type" => "date"
             }).valid?

      assert EdgeCondition.changeset(%{
               "field" => "sent_at",
               "op" => "lt",
               "value" => %{"from" => "now", "days" => -7},
               "type" => "datetime"
             }).valid?
    end

    test "accepts a plain ISO8601 string value" do
      assert EdgeCondition.changeset(%{
               "field" => "due_date",
               "op" => "gte",
               "value" => "2026-07-06",
               "type" => "date"
             }).valid?
    end

    test "rejects an unknown type" do
      changeset =
        EdgeCondition.changeset(%{
          "field" => "d",
          "op" => "lt",
          "value" => "today",
          "type" => "instant"
        })

      refute changeset.valid?
      assert {:type, {"is invalid", _}} = List.keyfind(changeset.errors, :type, 0)
    end

    test "rejects a value that does not resolve to the declared type" do
      changeset =
        EdgeCondition.changeset(%{
          "field" => "d",
          "op" => "lt",
          "value" => "not-a-date",
          "type" => "date"
        })

      refute changeset.valid?
      assert {:value, {"does not resolve to a date", []}} in changeset.errors
    end

    test "empty / not_empty need no resolvable value even with a type" do
      assert EdgeCondition.changeset(%{"field" => "d", "op" => "not_empty", "type" => "date"}).valid?

      assert EdgeCondition.changeset(%{"field" => "d", "op" => "empty", "type" => "datetime"}).valid?
    end
  end

  describe "evaluate/4 — date semantics" do
    test "term-order regression: Kernel comparison of %Date{} disagrees with chronology" do
      # ~D[2020-12-31] is chronologically BEFORE ~D[2021-01-01], but Erlang term order
      # compares %Date{} structs by map-key order (calendar, day, month, year) — so it
      # sorts by `day` first: 31 > 1. The legacy Kernel path is therefore wrong.
      older = ~D[2020-12-31]
      newer = ~D[2021-01-01]

      # Legacy path (type: nil): term order says older > newer — the bug.
      assert EdgeCondition.evaluate(:gt, older, newer)

      # Date-aware path: chronology wins. The authored/expected side is an ISO8601
      # string (as it always is in persisted JSONB), coerced via DateOperand.
      refute EdgeCondition.evaluate(:gt, older, "2021-01-01", type: "date")
      assert EdgeCondition.evaluate(:lt, older, "2021-01-01", type: "date")
    end

    test "eq / neq over dates" do
      assert EdgeCondition.evaluate(:eq, ~D[2026-07-06], "2026-07-06", type: "date")
      refute EdgeCondition.evaluate(:eq, ~D[2026-07-06], "2026-07-07", type: "date")
      assert EdgeCondition.evaluate(:neq, ~D[2026-07-06], "2026-07-07", type: "date")
    end

    test "gte / lte are inclusive at the boundary" do
      assert EdgeCondition.evaluate(:gte, ~D[2026-07-06], "2026-07-06", type: "date")
      assert EdgeCondition.evaluate(:lte, ~D[2026-07-06], "2026-07-06", type: "date")
      refute EdgeCondition.evaluate(:gte, ~D[2026-07-05], "2026-07-06", type: "date")
    end

    test "datetime comparison honors time-of-day" do
      actual = ~U[2026-07-06 09:00:00Z]
      assert EdgeCondition.evaluate(:lt, actual, "2026-07-06T10:00:00Z", type: "datetime")
      refute EdgeCondition.evaluate(:lt, actual, "2026-07-06T08:00:00Z", type: "datetime")
    end

    test "relative expected: 'older than 7 days' via lt against today-7d" do
      # Field 10 days before the fixed clock ⇒ older than 7 days ⇒ lt is true.
      assert EdgeCondition.evaluate(:lt, ~D[2026-06-26], %{"from" => "today", "days" => -7},
               type: "date",
               now: @now
             )

      # Field 3 days before ⇒ NOT older than 7 days ⇒ lt is false.
      refute EdgeCondition.evaluate(:lt, ~D[2026-07-03], %{"from" => "today", "days" => -7},
               type: "date",
               now: @now
             )
    end

    test "sentinel expected: 'today' / 'now'" do
      assert EdgeCondition.evaluate(:lt, ~D[2026-07-05], "today", type: "date", now: @now)

      assert EdgeCondition.evaluate(:lt, ~U[2026-07-06 15:00:00Z], "now",
               type: "datetime",
               now: @now
             )
    end

    test "empty / not_empty ignore type" do
      assert EdgeCondition.evaluate(:empty, nil, "today", type: "date")
      assert EdgeCondition.evaluate(:not_empty, ~D[2026-07-06], "today", type: "date")
    end

    test "atom type and string operators are normalized for date comparisons" do
      assert EdgeCondition.evaluate("gte", ~D[2026-07-06], "2026-07-06", type: :date)
      refute EdgeCondition.evaluate("lte", ~D[2026-07-07], "2026-07-06", type: :date)
    end

    test "unknown types use the legacy evaluation path" do
      assert EdgeCondition.evaluate(:gt, 5, 3, type: "unknown")
    end

    test "non-date operators with a date type use legacy semantics" do
      assert EdgeCondition.evaluate(:in, "open", ["open", "closed"], type: "date")
      refute EdgeCondition.evaluate(:in, "archived", ["open", "closed"], type: "date")
    end

    test "an unresolvable operand yields false (branch pruned), never a crash" do
      refute EdgeCondition.evaluate(:lt, "not-a-date", "today", type: "date", now: @now)
      refute EdgeCondition.evaluate(:lt, ~D[2026-07-06], "garbage", type: "date", now: @now)
      refute EdgeCondition.evaluate(:lt, nil, "today", type: "date", now: @now)
    end

    test "type: nil is the legacy Kernel path unchanged" do
      assert EdgeCondition.evaluate(:gt, 5, 3, type: nil)
      assert EdgeCondition.evaluate(:eq, "male", "male", [])
    end

    property "date gt/lt/eq agree with Date.compare/2" do
      base = ~D[2020-01-01]

      check all(
              da <- integer(-3650..3650),
              db <- integer(-3650..3650)
            ) do
        a = Date.add(base, da)
        b = Date.add(base, db)
        cmp = Date.compare(a, b)
        # actual is a %Date{} fact; expected is the authored ISO8601 string.
        expected = Date.to_iso8601(b)

        assert EdgeCondition.evaluate(:gt, a, expected, type: "date") == (cmp == :gt)
        assert EdgeCondition.evaluate(:lt, a, expected, type: "date") == (cmp == :lt)
        assert EdgeCondition.evaluate(:eq, a, expected, type: "date") == (cmp == :eq)
      end
    end
  end
end

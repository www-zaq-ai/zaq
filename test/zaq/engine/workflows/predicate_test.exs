defmodule Zaq.Engine.Workflows.PredicateTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Workflows.Predicate

  describe "ops/0" do
    test "returns the full operator vocabulary" do
      ops = Predicate.ops()
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

  describe "evaluate/3 — :eq" do
    test "returns true when equal" do
      assert Predicate.evaluate(:eq, "male", "male")
      assert Predicate.evaluate(:eq, 1, 1)
      assert Predicate.evaluate(:eq, nil, nil)
    end

    test "returns false when not equal" do
      refute Predicate.evaluate(:eq, "male", "female")
      refute Predicate.evaluate(:eq, 1, 2)
    end
  end

  describe "evaluate/3 — :neq" do
    test "returns true when not equal" do
      assert Predicate.evaluate(:neq, "male", "female")
      assert Predicate.evaluate(:neq, 1, 2)
    end

    test "returns false when equal" do
      refute Predicate.evaluate(:neq, "x", "x")
    end
  end

  describe "evaluate/3 — :gt / :lt / :gte / :lte" do
    test ":gt" do
      assert Predicate.evaluate(:gt, 5, 3)
      refute Predicate.evaluate(:gt, 3, 5)
      refute Predicate.evaluate(:gt, 3, 3)
    end

    test ":lt" do
      assert Predicate.evaluate(:lt, 2, 4)
      refute Predicate.evaluate(:lt, 4, 2)
      refute Predicate.evaluate(:lt, 2, 2)
    end

    test ":gte" do
      assert Predicate.evaluate(:gte, 5, 5)
      assert Predicate.evaluate(:gte, 6, 5)
      refute Predicate.evaluate(:gte, 4, 5)
    end

    test ":lte" do
      assert Predicate.evaluate(:lte, 3, 3)
      assert Predicate.evaluate(:lte, 2, 3)
      refute Predicate.evaluate(:lte, 4, 3)
    end
  end

  describe "evaluate/3 — :not_empty / :empty" do
    test ":empty returns true for nil, empty string, empty list, empty map" do
      assert Predicate.evaluate(:empty, nil, nil)
      assert Predicate.evaluate(:empty, "", nil)
      assert Predicate.evaluate(:empty, [], nil)
      assert Predicate.evaluate(:empty, %{}, nil)
    end

    test ":empty returns false for non-empty values" do
      refute Predicate.evaluate(:empty, "x", nil)
      refute Predicate.evaluate(:empty, [1], nil)
      refute Predicate.evaluate(:empty, %{a: 1}, nil)
      refute Predicate.evaluate(:empty, 0, nil)
    end

    test ":not_empty is the inverse of :empty" do
      assert Predicate.evaluate(:not_empty, "x", nil)
      assert Predicate.evaluate(:not_empty, [1], nil)
      refute Predicate.evaluate(:not_empty, nil, nil)
      refute Predicate.evaluate(:not_empty, "", nil)
    end
  end

  describe "evaluate/3 — :in" do
    test "returns true when actual is in expected list" do
      assert Predicate.evaluate(:in, "male", ["male", "female"])
      assert Predicate.evaluate(:in, 3, [1, 2, 3])
    end

    test "returns false when actual is not in expected list" do
      refute Predicate.evaluate(:in, "other", ["male", "female"])
    end

    test "raises ArgumentError when expected is not a list" do
      assert_raise ArgumentError, ~r/requires a list/, fn ->
        Predicate.evaluate(:in, "x", "not_a_list")
      end
    end
  end

  describe "evaluate/3 — unknown op" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/unknown predicate op/, fn ->
        Predicate.evaluate(:bogus_op, "x", "y")
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
        result = Predicate.evaluate(op, a, b)
        assert is_boolean(result)
      end
    end

    property ":in always returns boolean when expected is a list" do
      check all(
              actual <- one_of([integer(), string(:alphanumeric), constant(nil)]),
              expected <- list_of(one_of([integer(), string(:alphanumeric), constant(nil)]))
            ) do
        result = Predicate.evaluate(:in, actual, expected)
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
        assert is_boolean(Predicate.evaluate(:empty, val, nil))
        assert is_boolean(Predicate.evaluate(:not_empty, val, nil))
      end
    end

    property "unknown op always raises ArgumentError" do
      known = MapSet.new(Predicate.ops())

      check all(
              op <-
                atom(:alphanumeric)
                |> filter(&(not MapSet.member?(known, &1)))
                |> filter(&(&1 != :""))
            ) do
        assert_raise ArgumentError, fn ->
          Predicate.evaluate(op, "x", "y")
        end
      end
    end
  end
end

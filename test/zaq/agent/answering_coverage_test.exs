defmodule Zaq.Agent.AnsweringCoverageTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Answering

  # ---------------------------------------------------------------------------
  # no_answer? — additional signals
  # ---------------------------------------------------------------------------

  describe "no_answer?/1 — additional no-answer signals" do
    test "detects 'i do not have'" do
      assert Answering.no_answer?("I do not have that information.")
    end

    test "detects 'not enough information'" do
      assert Answering.no_answer?("There is not enough information to answer.")
    end

    test "detects 'i can't answer'" do
      assert Answering.no_answer?("I can't answer that based on context.")
    end

    test "detects 'outside my knowledge'" do
      assert Answering.no_answer?("That is outside my knowledge.")
    end

    test "detects 'no relevant'" do
      assert Answering.no_answer?("No relevant documents were found.")
    end
  end

  # ---------------------------------------------------------------------------
  # clean_answer — edge cases
  # ---------------------------------------------------------------------------

  describe "clean_answer/1 — edge cases" do
    test "returns empty string unchanged" do
      assert Answering.clean_answer("") == ""
    end

    test "removes opening code fence with language tag" do
      assert Answering.clean_answer("```elixir\ndefmodule Foo do\nend\n```") ==
               "defmodule Foo do\nend"
    end

    test "passes through non-string map as-is" do
      assert Answering.clean_answer(%{key: "value"}) == %{key: "value"}
    end

    test "passes through list as-is" do
      assert Answering.clean_answer([1, 2, 3]) == [1, 2, 3]
    end
  end
end

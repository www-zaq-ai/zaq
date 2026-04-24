defmodule Zaq.Agent.AnsweringTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.Answering

  describe "no_answer?/1" do
    test "returns true for no-information answers" do
      assert Answering.no_answer?("I don't have enough information to answer that.")
      assert Answering.no_answer?("There is no information available on this topic.")
      assert Answering.no_answer?("I cannot answer this question based on the context.")
      assert Answering.no_answer?("No relevant data was found.")
      assert Answering.no_answer?("This is outside my knowledge base.")
    end

    test "returns false for actual answers" do
      refute Answering.no_answer?("The vacation policy allows 20 days per year.")
      refute Answering.no_answer?("Elixir is a functional programming language.")
    end

    test "is case-insensitive" do
      assert Answering.no_answer?("I DON'T HAVE the information you need.")
    end

    test "returns false for non-binary input" do
      refute Answering.no_answer?(nil)
      refute Answering.no_answer?(123)
    end
  end

  describe "clean_answer/1" do
    test "trims whitespace" do
      assert Answering.clean_answer("  hello  ") == "hello"
    end

    test "removes surrounding quotes" do
      assert Answering.clean_answer("\"hello world\"") == "hello world"
    end

    test "removes markdown code fences" do
      assert Answering.clean_answer("```\nhello\n```") == "hello"
      assert Answering.clean_answer("```json\n{\"a\": 1}\n```") == "{\"a\": 1}"
    end

    test "passes through non-binary input" do
      assert Answering.clean_answer(nil) == nil
      assert Answering.clean_answer(123) == 123
    end
  end
end

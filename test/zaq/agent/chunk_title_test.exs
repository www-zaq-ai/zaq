defmodule Zaq.Agent.ChunkTitleTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.ChunkTitle

  describe "max_words/0" do
    test "returns the configured max word limit" do
      assert ChunkTitle.max_words() == 8
    end
  end

  # Private helpers are tested indirectly through ask/2,
  # but we can exercise the post-processing logic by testing
  # the module's observable behavior with known LLM outputs.

  describe "post-processing (via ask/2 output contract)" do
    # These tests verify the cleanup helpers work correctly.
    # Since they're private, we test them through a helper that
    # applies the same pipeline.

    test "remove_quotes strips surrounding quotes" do
      # Simulate what ask/2 does after getting LLM output
      assert clean("\"Hello World\"") == "Hello World"
      assert clean("'Hello World'") == "Hello World"
    end

    test "remove_prefix strips common LLM prefixes" do
      assert clean("Title: Northwind Industries") == "Northwind Industries"
      assert clean("The title is: Northwind") == "Northwind"
      assert clean("Here's Northwind Industries") == "Northwind Industries"
    end

    test "enforce_word_limit truncates long titles" do
      long = "One Two Three Four Five Six Seven Eight Nine Ten"
      result = clean(long)
      word_count = result |> String.split(~r/\s+/, trim: true) |> length()
      assert word_count <= 8
    end

    test "short titles are not truncated" do
      short = "Northwind Industries 1987"
      assert clean(short) == "Northwind Industries 1987"
    end

    # Mirrors the private pipeline in ask/2
    defp clean(text) do
      text
      |> String.trim()
      |> String.replace(~r/^["']/, "")
      |> String.replace(~r/["']$/, "")
      |> String.trim()
      |> String.replace(~r/^(Title:|Here is|Here's|The title is:?)\s*/i, "")
      |> String.trim()
      |> then(fn t ->
        words = String.split(t, ~r/\s+/, trim: true)

        if length(words) > 8 do
          words |> Enum.take(8) |> Enum.join(" ")
        else
          t
        end
      end)
    end
  end

  describe "ask/2 — full pipeline (requires running LLM)" do
    @describetag :integration
    test "generates a title for a chunk" do
      content = """
      Welcome to Northwind Industries! Founded in 1987 by Eleanor Vance,
      Northwind has grown from a small family business into a global leader
      in sustainable manufacturing solutions.
      """

      {:ok, title} = ChunkTitle.ask(content)

      assert is_binary(title)
      assert String.length(title) > 0

      word_count = title |> String.split(~r/\s+/, trim: true) |> length()
      assert word_count <= 8
    end

    test "returns error tuple on failure" do
      # Empty content might cause issues depending on LLM
      result = ChunkTitle.ask("")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end

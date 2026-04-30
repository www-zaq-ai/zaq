defmodule Zaq.Utils.TextUtils do
  @moduledoc false

  @title_prefix_regex ~r/^(Title:|Here is|Here's|The title is:?)\s*/i

  @doc """
  Truncates `text` to at most `max_words` words.

  Returns the original string unchanged if it is already within the limit.
  Words are split on any whitespace sequence.

  ## Examples

      iex> Zaq.Utils.TextUtils.enforce_word_limit("one two three", 5)
      "one two three"

      iex> Zaq.Utils.TextUtils.enforce_word_limit("one two three four five six", 4)
      "one two three four"

      iex> Zaq.Utils.TextUtils.enforce_word_limit("hello", 1)
      "hello"

      iex> Zaq.Utils.TextUtils.enforce_word_limit("", 10)
      ""

  """
  def enforce_word_limit(text, max_words) do
    words = String.split(text, ~r/\s+/, trim: true)
    if length(words) > max_words, do: words |> Enum.take(max_words) |> Enum.join(" "), else: text
  end

  @doc """
  Normalizes LLM-generated title text by stripping surrounding quotes, common
  preamble prefixes, and enforcing a maximum word count.

  Strips removed:
  - Leading/trailing whitespace
  - Leading/trailing single or double quotes
  - Prefixes matching `Title:`, `Here is`, `Here's`, `The title is:`
    (case-insensitive, with any trailing whitespace)

  ## Examples

      iex> Zaq.Utils.TextUtils.normalize_generated_title("My Report", 10)
      "My Report"

      iex> Zaq.Utils.TextUtils.normalize_generated_title(~s("Quarterly Review"), 10)
      "Quarterly Review"

      iex> Zaq.Utils.TextUtils.normalize_generated_title("Title: Q4 Summary", 10)
      "Q4 Summary"

      iex> Zaq.Utils.TextUtils.normalize_generated_title("Here's the title: Budget", 10)
      "the title: Budget"

      iex> Zaq.Utils.TextUtils.normalize_generated_title("  Here is   My Report  ", 2)
      "My Report"

      iex> Zaq.Utils.TextUtils.normalize_generated_title("one two three four five", 3)
      "one two three"

  """
  def normalize_generated_title(text, max_words) when is_binary(text) and is_integer(max_words) do
    text
    |> String.trim()
    |> String.replace(~r/^["']/, "")
    |> String.replace(~r/["']$/, "")
    |> String.trim()
    |> String.replace(@title_prefix_regex, "")
    |> String.trim()
    |> enforce_word_limit(max_words)
  end
end

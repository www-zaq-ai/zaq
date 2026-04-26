defmodule Zaq.Utils.TextUtils do
  @moduledoc false

  @title_prefix_regex ~r/^(Title:|Here is|Here's|The title is:?)\s*/i

  @doc "Truncates `text` to at most `max_words` words. Returns the original string if already within the limit."
  def enforce_word_limit(text, max_words) do
    words = String.split(text, ~r/\s+/, trim: true)
    if length(words) > max_words, do: words |> Enum.take(max_words) |> Enum.join(" "), else: text
  end

  @doc "Normalizes title-like text by trimming quotes/prefixes and enforcing max words."
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

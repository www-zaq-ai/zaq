defmodule Zaq.Utils.TextUtils do
  @moduledoc false

  @doc "Truncates `text` to at most `max_words` words. Returns the original string if already within the limit."
  def enforce_word_limit(text, max_words) do
    words = String.split(text, ~r/\s+/, trim: true)
    if length(words) > max_words, do: words |> Enum.take(max_words) |> Enum.join(" "), else: text
  end
end

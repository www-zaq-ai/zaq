defmodule Zaq.Ingestion.LanguageDetector do
  @moduledoc """
  Detects the natural language of a text chunk using the Lingua NIF.

  Returns a language identifier for BM25 search configuration (e.g. "english", "french") or
  "simple" when the language cannot be determined with sufficient confidence.

  Rules:
  - Fewer than 20 whitespace-separated tokens → "simple"
  - Confidence below 0.8 → "simple"
  - No match or unexpected response → "simple"
  """

  @confidence_threshold 0.8
  @min_token_count 20
  @min_query_token_count 3

  @doc """
  Detects the language of a chunk's `text` and returns the pg_search config name,
  or "simple" if detection fails or confidence is too low.
  Requires at least 20 tokens for reliable detection.
  """
  @spec detect(String.t()) :: String.t()
  def detect(text) when is_binary(text) do
    token_count = text |> String.split() |> length()

    if token_count < @min_token_count do
      "simple"
    else
      detect_with_confidence(text)
    end
  end

  @doc """
  Detects the language of a search query.
  Uses a lower token threshold (3) since queries are typically short.
  Falls back to "simple" so short or undetected queries match content indexed
  without a language-specific tokenizer.
  """
  @spec detect_query(String.t()) :: String.t()
  def detect_query(text) when is_binary(text) do
    token_count = text |> String.split() |> length()

    if token_count < @min_query_token_count do
      "simple"
    else
      detect_with_confidence(text)
    end
  end

  defp detect_with_confidence(text) do
    case lingua_module().detect(text, compute_language_confidence_values: true) do
      {:ok, :no_match} ->
        "simple"

      {:ok, scores} when is_list(scores) ->
        [{lang, confidence} | _] = Enum.sort_by(scores, &elem(&1, 1), :desc)

        if confidence >= @confidence_threshold do
          Atom.to_string(lang)
        else
          "simple"
        end

      {:ok, lang} when is_atom(lang) ->
        Atom.to_string(lang)

      _ ->
        "simple"
    end
  end

  defp lingua_module do
    Application.get_env(:zaq, :lingua_module, Lingua)
  end
end

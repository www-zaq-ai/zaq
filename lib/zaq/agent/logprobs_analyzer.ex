defmodule Zaq.Agent.LogprobsAnalyzer do
  @moduledoc """
  Utilities for confidence scoring based on LLM logprobs payloads.
  """

  @type confidence_error ::
          :invalid_logprobs_content | :missing_logprobs_content | :empty_logprobs_content

  # Convert logprob to probability
  def logprob_to_prob(logprob) do
    :math.exp(logprob)
  end

  # Calculate average confidence for the response
  @spec calculate_confidence(term(), boolean()) :: {:ok, float()} | {:error, confidence_error()}
  def calculate_confidence(logprobs_content, round \\ false) do
    with true <- is_list(logprobs_content) or {:error, :invalid_logprobs_content},
         true <- logprobs_content != [] or {:error, :empty_logprobs_content} do
      probs =
        logprobs_content
        |> Enum.flat_map(fn
          %{"logprob" => logprob} when is_number(logprob) -> [logprob_to_prob(logprob)]
          _ -> []
        end)

      case probs do
        [] ->
          {:error, :missing_logprobs_content}

        _ ->
          confidence = Enum.sum(probs) / length(probs)
          {:ok, maybe_round(confidence, round)}
      end
    end
  end

  @spec confidence_from_metadata(term(), boolean()) ::
          {:ok, float()} | {:error, confidence_error()}
  def confidence_from_metadata(metadata, round \\ false) do
    logprobs_content = get_in(metadata || %{}, [:logprobs, "content"])
    calculate_confidence(logprobs_content, round)
  end

  @spec confidence_from_metadata_or_nil(term(), boolean()) :: float() | nil
  def confidence_from_metadata_or_nil(metadata, round \\ false) do
    case confidence_from_metadata(metadata, round) do
      {:ok, score} -> score
      {:error, _reason} -> nil
    end
  end

  defp maybe_round(value, true), do: Float.round(value, 2)
  defp maybe_round(value, false), do: value

  # Get per-token confidence with tokens
  @spec token_confidences(term()) :: list()
  def token_confidences(logprobs_content) when not is_list(logprobs_content), do: []

  def token_confidences(logprobs_content) do
    Enum.flat_map(logprobs_content, fn
      %{"logprob" => logprob} = item when is_number(logprob) ->
        [
          %{
            token: item["token"],
            confidence: logprob_to_prob(logprob),
            alternatives: parse_alternatives(item["top_logprobs"])
          }
        ]

      _ ->
        []
    end)
  end

  defp parse_alternatives(alternatives) when not is_list(alternatives), do: []

  defp parse_alternatives(alternatives) do
    Enum.flat_map(alternatives, fn
      %{"logprob" => logprob} = alt when is_number(logprob) ->
        [%{token: alt["token"], confidence: logprob_to_prob(logprob)}]

      _ ->
        []
    end)
  end
end

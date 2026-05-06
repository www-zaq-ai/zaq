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
          %{logprob: logprob} when is_number(logprob) -> [logprob_to_prob(logprob)]
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
    logprobs_content = extract_logprobs_content(metadata)
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

  defp extract_logprobs_content(metadata) when is_map(metadata) do
    metadata
    |> extract_logprobs()
    |> case do
      %{} = logprobs -> Map.get(logprobs, :content) || Map.get(logprobs, "content")
      logprobs when is_list(logprobs) -> logprobs
      _ -> nil
    end
  end

  defp extract_logprobs_content(_), do: nil

  defp extract_logprobs(metadata),
    do: Map.get(metadata, :logprobs) || Map.get(metadata, "logprobs")

  # Get per-token confidence with tokens
  @spec token_confidences(term()) :: list()
  def token_confidences(logprobs_content) when not is_list(logprobs_content), do: []

  def token_confidences(logprobs_content) do
    Enum.flat_map(logprobs_content, fn
      %{"logprob" => logprob} = item when is_number(logprob) ->
        [
          %{
            token: item["token"] || item[:token],
            confidence: logprob_to_prob(logprob),
            alternatives: parse_alternatives(item["top_logprobs"] || item[:top_logprobs])
          }
        ]

      %{logprob: logprob} = item when is_number(logprob) ->
        [
          %{
            token: item[:token] || item["token"],
            confidence: logprob_to_prob(logprob),
            alternatives: parse_alternatives(item[:top_logprobs] || item["top_logprobs"])
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
        [%{token: alt["token"] || alt[:token], confidence: logprob_to_prob(logprob)}]

      %{logprob: logprob} = alt when is_number(logprob) ->
        [%{token: alt[:token] || alt["token"], confidence: logprob_to_prob(logprob)}]

      _ ->
        []
    end)
  end

  @doc """
  Extracts logprobs from a response map returned by `factory_module.await/2`.
  Returns the logprobs list or `nil` if not present.
  """
  @spec from_response(term()) :: list() | nil
  def from_response(%{logprobs: logprobs}) when is_list(logprobs), do: logprobs
  def from_response(%{provider_meta: %{logprobs: logprobs}}) when is_list(logprobs), do: logprobs

  def from_response(%{provider_meta: %{"logprobs" => logprobs}}) when is_list(logprobs),
    do: logprobs

  def from_response(%{result: result}), do: from_response(result)
  def from_response(_), do: nil

  @logprobs_error_terms ~w(logprob log_prob logprobs log_probs)

  @doc "Returns true if the error reason indicates the model does not support logprobs."
  @spec logprobs_unsupported_error?(term()) :: boolean()
  def logprobs_unsupported_error?(reason) do
    text = inspect(reason) |> String.downcase()
    Enum.any?(@logprobs_error_terms, &String.contains?(text, &1))
  end
end

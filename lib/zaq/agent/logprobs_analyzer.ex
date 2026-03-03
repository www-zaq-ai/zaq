defmodule Zaq.Agent.LogprobsAnalyzer do
  @moduledoc """
  LogprobsAnalyzer it calculates the confidence
  """
  # Convert logprob to probability
  def logprob_to_prob(logprob) do
    :math.exp(logprob)
  end

  # Calculate average confidence for the response
  def calculate_confidence(logprobs_content, round \\ false) do
    probs =
      logprobs_content
      |> Enum.map(& &1["logprob"])
      |> Enum.map(&logprob_to_prob/1)

    confidence = Enum.sum(probs) / length(probs)

    if round, do: Float.round(confidence, 2), else: confidence
  end

  # Get per-token confidence with tokens
  def token_confidences(logprobs_content) do
    Enum.map(logprobs_content, fn item ->
      %{
        token: item["token"],
        confidence: logprob_to_prob(item["logprob"]),
        alternatives:
          Enum.map(item["top_logprobs"], fn alt ->
            %{token: alt["token"], confidence: logprob_to_prob(alt["logprob"])}
          end)
      }
    end)
  end
end

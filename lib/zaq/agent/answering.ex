defmodule Zaq.Agent.Answering do
  @moduledoc """
  Response formulation agent.

  Receives context (retrieved chunks + user question) via a system prompt and
  generates a natural answer. Optionally computes a confidence score from
  logprobs when the LLM provider supports it.

  Uses DB-managed system prompt (`answering` slug) and provider-agnostic
  LLM configuration from `Zaq.Agent.LLM`.
  """

  require Logger

  alias Zaq.Agent.Answering.Result
  alias Zaq.Agent.{History, LLM, LLMRunner, LogprobsAnalyzer}
  alias Zaq.Engine.Telemetry

  @no_answer_signals [
    "i don't have",
    "i do not have",
    "no information",
    "not enough information",
    "i cannot answer",
    "i can't answer",
    "no relevant",
    "outside my knowledge"
  ]

  @doc """
  Generates an answer from the given system prompt (which should include
  retrieved context) and optional conversation history.

  ## Options

    * `:system_prompt` — override the DB prompt. When omitted, loads the
      active `"answering"` template and renders it.
    * `:history` — conversation history map.
    * `:include_confidence` — whether to compute logprobs confidence.
      Defaults to `true` when the LLM supports logprobs, `false` otherwise.
    * `:telemetry_dimensions` — optional dimensions for centralized telemetry metrics.

  ## Returns

    * `{:ok, %Zaq.Agent.Answering.Result{}}`
    * `{:error, String.t()}` — on failure
  """
  def ask(system_prompt, opts \\ []) do
    include_confidence =
      Keyword.get(opts, :include_confidence, LLM.supports_logprobs?())

    history =
      Keyword.get(opts, :history, [])
      |> History.build()

    question = Keyword.get(opts, :question)

    llm_config =
      LLM.chat_config()
      |> maybe_add_logprobs(include_confidence)

    telemetry_dimensions = Keyword.get(opts, :telemetry_dimensions, %{})

    Logger.info("Answering: Formulating response based on retrieved data")

    started_at = System.monotonic_time(:millisecond)

    case LLMRunner.run(
           llm_config: llm_config,
           system_prompt: system_prompt,
           history: history,
           question: question,
           error_prefix: "Failed to formulate response"
         ) do
      {:ok, updated_chain} ->
        case LLMRunner.content_result(updated_chain) do
          {:ok, answer} ->
            latency_ms = System.monotonic_time(:millisecond) - started_at

            bot_response = List.last(updated_chain.messages)
            usage = Map.get(bot_response.metadata, :usage) || %{}

            prompt_tokens = usage_value(usage, :input)
            completion_tokens = usage_value(usage, :output)

            total_tokens = maybe_total_tokens(prompt_tokens, completion_tokens)
            confidence_score = maybe_confidence_score(bot_response, include_confidence)
            log_token_usage(prompt_tokens, completion_tokens)

            result = %Result{
              answer: answer,
              confidence_score: confidence_score,
              latency_ms: latency_ms,
              prompt_tokens: prompt_tokens,
              completion_tokens: completion_tokens,
              total_tokens: total_tokens
            }

            emit_answer_telemetry(result, telemetry_dimensions)

            {:ok, result}

          {:error, reason} ->
            error_reason = "Failed to formulate response: #{reason}"
            Logger.error("Answering failed: #{error_reason}")
            {:error, error_reason}
        end

      {:error, reason} ->
        Logger.error("Answering failed: #{reason}")
        {:error, reason}
    end
  end

  @doc "Normalizes legacy answer payloads into the canonical result struct."
  @spec normalize_result(term()) :: {:ok, Result.t()} | {:error, :invalid_result}
  def normalize_result(%Result{} = result), do: {:ok, result}

  def normalize_result(%{answer: answer} = payload) when is_binary(answer) do
    {:ok, build_result(answer, payload)}
  end

  def normalize_result(%{"answer" => answer} = payload) when is_binary(answer) do
    {:ok, build_result(answer, payload)}
  end

  def normalize_result(answer) when is_binary(answer), do: {:ok, %Result{answer: answer}}
  def normalize_result(_), do: {:error, :invalid_result}

  defp build_result(answer, payload) do
    %Result{
      answer: answer,
      confidence_score: payload_confidence(payload),
      latency_ms: payload_int(payload, :latency_ms),
      prompt_tokens: payload_int(payload, :prompt_tokens),
      completion_tokens: payload_int(payload, :completion_tokens),
      total_tokens: payload_int(payload, :total_tokens)
    }
  end

  @doc """
  Checks whether the answer indicates the agent could not find relevant info.

  Returns `true` if the answer contains any of the known no-answer signals.
  """
  @spec no_answer?(String.t()) :: boolean()
  def no_answer?(answer) when is_binary(answer) do
    downcased = String.downcase(answer)
    Enum.any?(@no_answer_signals, &String.contains?(downcased, &1))
  end

  def no_answer?(_), do: false

  @doc """
  Cleans up the raw LLM answer by trimming whitespace and removing
  any surrounding quotes or markdown code fences.
  """
  @spec clean_answer(String.t()) :: String.t()
  def clean_answer(answer) when is_binary(answer) do
    answer
    |> String.trim()
    |> String.replace(~r/^```[\w]*\n?/, "")
    |> String.replace(~r/\n?```$/, "")
    |> String.trim("\"")
    |> String.trim()
  end

  def clean_answer(answer), do: answer

  # -- Private --

  defp maybe_add_logprobs(config, true), do: Map.put(config, :logprobs, true)
  defp maybe_add_logprobs(config, false), do: config

  defp usage_value(usage, key) do
    value = Map.get(usage, key) || Map.get(usage, Atom.to_string(key))
    as_int(value)
  end

  defp maybe_total_tokens(prompt_tokens, completion_tokens)
       when is_integer(prompt_tokens) and is_integer(completion_tokens),
       do: prompt_tokens + completion_tokens

  defp maybe_total_tokens(_, _), do: nil

  defp maybe_confidence_score(_bot_response, false), do: nil

  defp maybe_confidence_score(bot_response, true) do
    case LogprobsAnalyzer.confidence_from_metadata(bot_response.metadata, true) do
      {:ok, score} ->
        Logger.info("Response confidence: #{score * 100}%")
        score

      {:error, reason} ->
        Logger.warning("Response confidence unavailable: #{inspect(reason)}")
        nil
    end
  end

  defp log_token_usage(prompt_tokens, completion_tokens) do
    if is_integer(prompt_tokens), do: Logger.info("Input tokens: #{prompt_tokens}")
    if is_integer(completion_tokens), do: Logger.info("Output tokens: #{completion_tokens}")
  end

  defp payload_confidence(payload) do
    case payload_value(payload, :confidence) do
      %{score: score} when is_number(score) -> score * 1.0
      %{"score" => score} when is_number(score) -> score * 1.0
      score when is_number(score) -> score * 1.0
      _ -> nil
    end
  end

  defp payload_int(payload, key), do: payload |> payload_value(key) |> as_int()

  defp payload_value(payload, key),
    do: Map.get(payload, key) || Map.get(payload, Atom.to_string(key))

  defp as_int(value) when is_integer(value), do: value
  defp as_int(value) when is_float(value), do: trunc(value)
  defp as_int(_), do: nil

  defp emit_answer_telemetry(%Result{} = result, dimensions) do
    dims = normalize_dimensions(dimensions)

    if is_integer(result.latency_ms) do
      Telemetry.record("qa.answer.latency_ms", result.latency_ms, dims)
    end

    if is_integer(result.prompt_tokens) do
      Telemetry.record("qa.tokens.prompt", result.prompt_tokens, dims)
    end

    if is_integer(result.completion_tokens) do
      Telemetry.record("qa.tokens.completion", result.completion_tokens, dims)
    end

    if is_integer(result.total_tokens) do
      Telemetry.record("qa.tokens.total", result.total_tokens, dims)
    end

    if is_number(result.confidence_score) do
      Telemetry.record("qa.answer.confidence", result.confidence_score, dims)
      Telemetry.record(confidence_bucket_metric(result.confidence_score), 1, dims)
    end

    :ok
  end

  defp confidence_bucket_metric(score) when is_number(score) and score > 0.9,
    do: "qa.answer.confidence.bucket.gt_90"

  defp confidence_bucket_metric(score) when is_number(score) and score > 0.8,
    do: "qa.answer.confidence.bucket.between_80_90"

  defp confidence_bucket_metric(score) when is_number(score) and score > 0.7,
    do: "qa.answer.confidence.bucket.between_70_80"

  defp confidence_bucket_metric(score) when is_number(score) and score >= 0.5,
    do: "qa.answer.confidence.bucket.between_50_70"

  defp confidence_bucket_metric(_score), do: "qa.answer.confidence.bucket.lt_50"

  defp normalize_dimensions(dimensions) when is_map(dimensions), do: dimensions
  defp normalize_dimensions(_), do: %{}
end

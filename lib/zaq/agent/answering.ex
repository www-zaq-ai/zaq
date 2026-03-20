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

  alias LangChain.Chains.LLMChain
  alias LangChain.ChatModels.ChatOpenAI
  alias LangChain.Message
  alias LangChain.Utils.ChainResult
  alias Zaq.Agent.Answering.Result
  alias Zaq.Agent.{LLM, LogprobsAnalyzer}
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
      |> build_history()

    llm_config =
      LLM.chat_config()
      |> maybe_add_logprobs(include_confidence)

    telemetry_dimensions = Keyword.get(opts, :telemetry_dimensions, %{})

    Logger.info("Answering: Formulating response based on retrieved data")

    try do
      started_at = System.monotonic_time(:millisecond)

      {:ok, updated_chain} =
        LLMChain.new!(%{llm: ChatOpenAI.new!(llm_config)})
        |> LLMChain.add_message(Message.new_system!(system_prompt))
        |> then(fn chain ->
          if history != [], do: LLMChain.add_messages(chain, history), else: chain
        end)
        |> LLMChain.run()

      latency_ms = System.monotonic_time(:millisecond) - started_at

      answer = ChainResult.to_string!(updated_chain)
      bot_response = List.last(updated_chain.messages)
      usage = Map.get(bot_response.metadata, :usage) || %{}

      prompt_tokens = usage_value(usage, :input)
      completion_tokens = usage_value(usage, :output)

      total_tokens =
        case {prompt_tokens, completion_tokens} do
          {p, c} when is_integer(p) and is_integer(c) -> p + c
          _ -> nil
        end

      confidence_score =
        if include_confidence do
          logprobs_content = bot_response.metadata.logprobs["content"]

          score = LogprobsAnalyzer.calculate_confidence(logprobs_content, true)
          Logger.info("Response confidence: #{score * 100}%")
          score
        else
          nil
        end

      if is_integer(prompt_tokens), do: Logger.info("Input tokens: #{prompt_tokens}")
      if is_integer(completion_tokens), do: Logger.info("Output tokens: #{completion_tokens}")

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
    rescue
      e ->
        Logger.error("Answering failed: #{inspect(e)}")
        {:error, "Failed to formulate response: #{Exception.message(e)}"}
    end
  end

  @doc "Normalizes legacy answer payloads into the canonical result struct."
  @spec normalize_result(term()) :: {:ok, Result.t()} | {:error, :invalid_result}
  def normalize_result(%Result{} = result), do: {:ok, result}

  def normalize_result(%{answer: answer} = payload) when is_binary(answer) do
    confidence =
      case Map.get(payload, :confidence) || Map.get(payload, "confidence") do
        %{score: score} when is_number(score) -> score * 1.0
        %{"score" => score} when is_number(score) -> score * 1.0
        score when is_number(score) -> score * 1.0
        _ -> nil
      end

    {:ok,
     %Result{
       answer: answer,
       confidence_score: confidence,
       latency_ms: as_int(Map.get(payload, :latency_ms) || Map.get(payload, "latency_ms")),
       prompt_tokens:
         as_int(Map.get(payload, :prompt_tokens) || Map.get(payload, "prompt_tokens")),
       completion_tokens:
         as_int(Map.get(payload, :completion_tokens) || Map.get(payload, "completion_tokens")),
       total_tokens: as_int(Map.get(payload, :total_tokens) || Map.get(payload, "total_tokens"))
     }}
  end

  def normalize_result(answer) when is_binary(answer), do: {:ok, %Result{answer: answer}}
  def normalize_result(_), do: {:error, :invalid_result}

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

  defp build_history([]), do: []

  defp build_history(history) when is_map(history) do
    Enum.map(history, fn
      {_timestamp, %{"body" => msg, "type" => "bot"}} ->
        msg = if is_binary(msg), do: msg, else: Jason.encode!(msg)
        Message.new_assistant!(msg)

      {_timestamp, %{"body" => msg, "type" => "user"}} ->
        msg = if is_binary(msg), do: msg, else: Jason.encode!(msg)
        Message.new_user!(msg)
    end)
  end

  defp maybe_add_logprobs(config, true), do: Map.put(config, :logprobs, true)
  defp maybe_add_logprobs(config, false), do: config

  defp usage_value(usage, key) do
    value = Map.get(usage, key) || Map.get(usage, Atom.to_string(key))
    as_int(value)
  end

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
    end

    :ok
  end

  defp normalize_dimensions(dimensions) when is_map(dimensions), do: dimensions
  defp normalize_dimensions(_), do: %{}
end

defmodule Zaq.Agent.Answering do
  @moduledoc """
  Response formulation agent.

  Receives context (retrieved chunks + user question) via a system prompt and
  generates a natural answer using a transient Jido AI agent with ReAct tools.

  Uses DB-managed system prompt (`answering` slug) and provider-agnostic
  LLM configuration from `Zaq.Agent.Factory`.
  """

  require Logger

  alias ReqLLM.Context
  alias Zaq.Agent.Answering.Result
  alias Zaq.Agent.{Factory, History, LogprobsAnalyzer}
  alias Zaq.Engine.Telemetry

  @answering_tools [
    Zaq.Agent.Tools.SearchKnowledgeBase,
    Zaq.Agent.Tools.AskForClarification
  ]

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

  Starts a transient Jido AI agent with ReAct tools, sets the system prompt,
  and asks the question. The agent is stopped after the response is received.

  ## Options

    * `:question` — the user question string.
    * `:history` — conversation history map.
    * `:person_id` — required for tool calls (knowledge base search).
    * `:team_ids` — optional team IDs for permission filtering.
    * `:telemetry_dimensions` — optional dimensions for centralized telemetry metrics.
    * `:factory_module` — override the factory module (for testing).

  ## Returns

    * `{:ok, %Zaq.Agent.Answering.Result{}}`
    * `{:error, String.t()}` — on failure
  """
  def ask(system_prompt, opts \\ []) do
    history = opts |> Keyword.get(:history, []) |> History.build()
    question = Keyword.get(opts, :question)
    person_id = Keyword.get(opts, :person_id)
    team_ids = Keyword.get(opts, :team_ids, [])
    telemetry_dimensions = Keyword.get(opts, :telemetry_dimensions, %{})
    factory_mod = Keyword.get(opts, :factory_module, Factory)

    Logger.info("Answering: Formulating response based on retrieved data")

    started_at = System.monotonic_time(:millisecond)

    messages =
      if question do
        history ++ [Context.user(question)]
      else
        history
      end

    server_id = "answering_#{System.unique_integer([:positive])}"

    ask_opts = [
      tools: @answering_tools,
      llm_opts: Factory.generation_opts(),
      context: %{person_id: person_id, team_ids: team_ids},
      timeout: 60_000
    ]

    with {:ok, server} <-
           Jido.AgentServer.start_link(
             agent: Factory,
             id: server_id,
             jido: Zaq.Agent.Jido,
             initial_state: %{model: Factory.build_model_spec()}
           ),
         :ok <- set_system_prompt(server, system_prompt) do
      logprobs_ref = LogprobsAnalyzer.capture_logprobs()

      result =
        try do
          with {:ok, request} <-
                 factory_mod.ask(server, History.format_messages(messages), ask_opts) do
            factory_mod.await(request, timeout: 60_000)
          end
        after
          GenServer.stop(server, :normal)
        end

      logprobs = LogprobsAnalyzer.release_logprobs(logprobs_ref)
      parse_agent_result(result, started_at, telemetry_dimensions, logprobs)
    else
      {:error, reason} ->
        error_reason = "Failed to start answering agent: #{inspect(reason)}"
        Logger.error("Answering failed: #{error_reason}")
        {:error, error_reason}
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

  defp set_system_prompt(server, prompt) do
    case Jido.AI.set_system_prompt(server, prompt, timeout: 10_000) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_agent_result({:ok, handle}, started_at, telemetry_dimensions, logprobs) do
    latency_ms = System.monotonic_time(:millisecond) - started_at
    clarification = extract_clarification(handle)
    answer_text = extract_answer_text(handle)
    confidence = LogprobsAnalyzer.confidence_from_metadata_or_nil(%{logprobs: logprobs})
    build_ok_result(clarification, answer_text, latency_ms, telemetry_dimensions, confidence)
  end

  defp parse_agent_result({:error, reason}, _started_at, _telemetry_dimensions, _logprobs) do
    error_reason = "Failed to formulate response: #{inspect(reason)}"

    if LogprobsAnalyzer.logprobs_unsupported_error?(reason) do
      Logger.error(
        "Answering failed: the configured model does not support logprobs. " <>
          "Disable it in System Config → LLM → supports_logprobs. Original error: #{inspect(reason)}"
      )
    else
      Logger.error("Answering failed: #{error_reason}")
    end

    {:error, error_reason}
  end

  defp build_ok_result(clarification, _answer_text, latency_ms, telemetry_dimensions, confidence)
       when is_binary(clarification) do
    result = %Result{
      answer: clarification,
      clarification: clarification,
      latency_ms: latency_ms,
      confidence_score: confidence
    }

    emit_answer_telemetry(result, telemetry_dimensions)
    {:ok, result}
  end

  defp build_ok_result(_clarification, answer_text, latency_ms, telemetry_dimensions, confidence)
       when is_binary(answer_text) do
    if String.trim(answer_text) == "" do
      emit_empty_answer_error()
    else
      result = %Result{answer: answer_text, latency_ms: latency_ms, confidence_score: confidence}
      emit_answer_telemetry(result, telemetry_dimensions)
      {:ok, result}
    end
  end

  defp build_ok_result(
         _clarification,
         _answer_text,
         _latency_ms,
         _telemetry_dimensions,
         _confidence
       ) do
    emit_empty_answer_error()
  end

  defp emit_empty_answer_error do
    error_reason = "Failed to formulate response: Empty assistant response content"
    Logger.error("Answering failed: #{error_reason}")
    {:error, error_reason}
  end

  defp extract_clarification(%{result: %{clarification_needed: true, question: q}}), do: q
  defp extract_clarification(%{clarification_needed: true, question: q}), do: q
  defp extract_clarification(_), do: nil

  defp extract_answer_text(%{result: text}) when is_binary(text), do: text
  defp extract_answer_text(%{response: text}) when is_binary(text), do: text
  defp extract_answer_text(text) when is_binary(text), do: text
  defp extract_answer_text(_), do: nil

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

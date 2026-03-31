defmodule Zaq.Agent.Pipeline do
  @moduledoc """
  Shared answering pipeline for all retrieval channels.

  Runs: validate → retrieve → extract → answer → safety check → knowledge gap capture.

  Designed so every retrieval channel (Mattermost, Slack, Teams, chat widget, …) uses
  the same logic without duplication. Adding a new channel requires no changes here.

  ## Knowledge Gap capture

  When the bot cannot answer, `LicenseManager.Paid.KnowledgeGap.capture/1` is called
  automatically. The call is guarded with `function_exported?/3` so it is a safe no-op
  in open-source deployments where the licensed module is not loaded.

  ## Hook integration

  The pipeline dispatches the following hook events:

    * `:before_retrieval`        — sync; may mutate `%{question: string}` or halt
    * `:after_retrieval`         — sync + async; payload is the retrieval result map
    * `:before_answering`        — sync; may mutate the retrieval/extraction payload
    * `:after_answer_generated`  — sync + async; payload is `%{answer: result}`
    * `:after_pipeline_complete` — async; payload is the final result map

  ## Options

    * `:history`            — conversation history map (default: `%{}`)
    * `:role_ids`           — role IDs for document filtering (default: `[]`)
    * `:on_status`          — 2-arity fn `(stage, message) :: :ok` for progress
                              callbacks; used by LiveView to push status updates
                              (default: silent no-op)
    * `:hooks`              — Hooks module override (default: `Zaq.Hooks`)
    * `:node_router`        — NodeRouter module override
    * `:retrieval`          — Retrieval module override
    * `:document_processor` — DocumentProcessor module override
    * `:answering`          — Answering module override
    * `:prompt_guard`       — PromptGuard module override
    * `:prompt_template`    — PromptTemplate module override

  ## Returns

  Always returns a plain map with a stable shape:

    * `:answer`
    * `:confidence_score`
    * `:latency_ms`
    * `:prompt_tokens`
    * `:completion_tokens`
    * `:total_tokens`
    * `:error`
  """

  require Logger
  alias Zaq.Agent.Answering
  alias Zaq.Agent.Answering.Result
  alias Zaq.Engine.Telemetry

  @no_answer_signal "I don't have enough information to answer that question."

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec run(String.t(), keyword()) :: map()
  def run(question, opts \\ []) do
    history = Keyword.get(opts, :history, %{})
    role_ids = Keyword.get(opts, :role_ids, [])
    on_status = Keyword.get(opts, :on_status, fn _stage, _msg -> :ok end)
    ctx = %{trace_id: generate_trace_id(), node: node()}
    hooks = hooks_mod(opts)

    with {:ok, clean_msg} <- prompt_guard(opts).validate(question),
         {:ok, retrieval_payload} <-
           hooks.dispatch_before(:before_retrieval, %{question: clean_msg}, ctx),
         :ok <- on_status.(:retrieving, "ZAQ is searching your knowledge base…"),
         {:ok, retrieval_result} <- do_retrieval(retrieval_payload.question, history, opts),
         :ok <- hooks.dispatch_after(:after_retrieval, retrieval_result, ctx),
         :ok <- on_status.(:retrieving, retrieval_result.positive_answer),
         {:ok, answering_payload} <-
           hooks.dispatch_before(:before_answering, retrieval_result, ctx),
         {:ok, extraction_result} <- do_query_extraction(answering_payload, role_ids, opts),
         :ok <- on_status.(:answering, "Formulating your answer…"),
         {:ok, answer_result} <-
           do_answering(clean_msg, extraction_result, answering_payload, history, opts),
         {:ok, safe_answer} <- prompt_guard(opts).output_safe?(answer_result.answer) do
      :ok = hooks.dispatch_after(:after_answer_generated, %{answer: answer_result}, ctx)

      result =
        if answering_mod(opts).no_answer?(safe_answer) do
          :ok = record_no_answer_telemetry(opts)

          answer_result
          |> result_from_answering(answering_mod(opts).clean_answer(safe_answer), 0.0)
          |> Map.merge(%{
            knowledge_gap: true,
            question: question,
            generated_query: retrieval_result.query,
            history: history
          })
        else
          confidence_score = answer_result.confidence_score || 1.0
          result_from_answering(answer_result, safe_answer, confidence_score)
        end

      :ok =
        hooks.dispatch_after(
          :after_pipeline_complete,
          Map.put(result, :chunks, extraction_result),
          ctx
        )

      result
    else
      {:halt, _payload} ->
        error_result("Request was halted by a pipeline hook.")

      {:error, :prompt_injection} ->
        error_result("I can only help with ZAQ-related questions.")

      {:error, :role_play_attempt} ->
        error_result("I can only help with ZAQ-related questions.")

      {:error, {:leaked, _phrase}} ->
        Logger.warning("[Pipeline] PromptGuard: output leak detected, blocking response")
        error_result("I can only help with ZAQ-related questions.")

      {:error, :no_results, negative_answer} ->
        :ok = record_no_answer_telemetry(opts)

        result =
          negative_answer
          |> success_result(0.0)
          |> Map.merge(%{
            knowledge_gap: true,
            question: question,
            generated_query: nil,
            history: history
          })

        :ok = hooks.dispatch_after(:after_pipeline_complete, Map.put(result, :chunks, []), ctx)
        result

      {:error, :no_results} ->
        :ok = record_no_answer_telemetry(opts)

        result =
          "I couldn't find relevant information to answer your question."
          |> success_result(0.0)
          |> Map.merge(%{
            knowledge_gap: true,
            question: question,
            generated_query: nil,
            history: history
          })

        :ok = hooks.dispatch_after(:after_pipeline_complete, Map.put(result, :chunks, []), ctx)
        result

      {:error, reason} ->
        Logger.error("[Pipeline] Error: #{inspect(reason)}")
        error_result("Sorry, something went wrong. Please try again.")
    end
  end

  # ---------------------------------------------------------------------------
  # Pipeline steps
  # ---------------------------------------------------------------------------

  defp do_retrieval(clean_msg, history, opts) do
    case node_router(opts).call(:agent, retrieval_mod(opts), :ask, [clean_msg, [history: history]]) do
      {:ok,
       %{
         "query" => query,
         "language" => language,
         "positive_answer" => positive_answer,
         "negative_answer" => negative_answer
       }}
      when query != "" ->
        {:ok,
         %{
           query: query,
           language: language,
           positive_answer: positive_answer,
           negative_answer: negative_answer
         }}

      {:ok, %{"negative_answer" => negative_answer}} ->
        {:error, :no_results, negative_answer}

      {:ok, %{"error" => _}} ->
        {:error, :blocked}

      {:ok, _} ->
        {:error, :no_results}

      error ->
        error
    end
  end

  defp do_query_extraction(%{query: query, negative_answer: negative_answer}, role_ids, opts) do
    case node_router(opts).call(
           :ingestion,
           document_processor_mod(opts),
           :query_extraction,
           [query, role_ids]
         ) do
      {:ok, results} when results != [] -> {:ok, results}
      {:ok, []} -> {:error, :no_results, negative_answer}
      {:error, _} -> {:error, :no_results, negative_answer}
    end
  end

  defp do_answering(question, query_results, retrieval, history, opts) do
    language = Map.get(retrieval, :language, "en")

    retrieved_data =
      Enum.map(query_results, fn %{"content" => content, "source" => source} ->
        %{"content" => content, "source" => source}
      end)

    system_prompt =
      prompt_template_mod(opts).render("answering", %{
        question: question,
        retrieved_data: Jason.encode!(retrieved_data),
        language: language,
        no_answer_signal: @no_answer_signal,
        has_history: history != %{}
      })

    answer_opts = [
      history: history,
      question: question,
      telemetry_dimensions: telemetry_dimensions(opts)
    ]

    ask_args =
      if function_exported?(answering_mod(opts), :ask, 2) do
        [system_prompt, answer_opts]
      else
        [system_prompt]
      end

    case node_router(opts).call(:agent, answering_mod(opts), :ask, ask_args) do
      {:ok, answer} -> normalize_answer_result(answering_mod(opts), answer)
      error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp normalize_answer_result(module, %Result{} = result) when module == Answering,
    do: {:ok, result}

  defp normalize_answer_result(module, result) do
    if function_exported?(module, :normalize_result, 1) do
      module.normalize_result(result)
    else
      Answering.normalize_result(result)
    end
  end

  defp telemetry_dimensions(opts) do
    Keyword.get(opts, :telemetry_dimensions, %{})
  end

  defp record_no_answer_telemetry(opts) do
    Telemetry.record("qa.no_answer.count", 1, telemetry_dimensions(opts))
  end

  defp result_from_answering(%Result{} = result, answer, confidence_score) do
    %{
      answer: answer,
      confidence_score: confidence_score,
      latency_ms: result.latency_ms,
      prompt_tokens: result.prompt_tokens,
      completion_tokens: result.completion_tokens,
      total_tokens: result.total_tokens,
      error: false
    }
  end

  defp success_result(answer, confidence_score) do
    %{
      answer: answer,
      confidence_score: confidence_score,
      latency_ms: nil,
      prompt_tokens: nil,
      completion_tokens: nil,
      total_tokens: nil,
      error: false
    }
  end

  defp error_result(answer) do
    %{
      answer: answer,
      confidence_score: 0.0,
      latency_ms: nil,
      prompt_tokens: nil,
      completion_tokens: nil,
      total_tokens: nil,
      error: true
    }
  end

  # ---------------------------------------------------------------------------
  # Configurable modules (allow overrides for testing and per-channel config)
  # ---------------------------------------------------------------------------

  defp generate_trace_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp hooks_mod(opts) do
    Keyword.get(opts, :hooks, Application.get_env(:zaq, :pipeline_hooks_module, Zaq.Hooks))
  end

  defp node_router(opts) do
    Keyword.get(
      opts,
      :node_router,
      Application.get_env(:zaq, :pipeline_node_router_module, Zaq.NodeRouter)
    )
  end

  defp retrieval_mod(opts) do
    Keyword.get(
      opts,
      :retrieval,
      Application.get_env(:zaq, :pipeline_retrieval_module, Zaq.Agent.Retrieval)
    )
  end

  defp document_processor_mod(opts) do
    Keyword.get(
      opts,
      :document_processor,
      Application.get_env(
        :zaq,
        :pipeline_document_processor_module,
        Zaq.Ingestion.DocumentProcessor
      )
    )
  end

  defp answering_mod(opts) do
    Keyword.get(
      opts,
      :answering,
      Application.get_env(:zaq, :pipeline_answering_module, Zaq.Agent.Answering)
    )
  end

  defp prompt_guard(opts) do
    Keyword.get(
      opts,
      :prompt_guard,
      Application.get_env(:zaq, :pipeline_prompt_guard_module, Zaq.Agent.PromptGuard)
    )
  end

  defp prompt_template_mod(opts) do
    Keyword.get(
      opts,
      :prompt_template,
      Application.get_env(:zaq, :pipeline_prompt_template_module, Zaq.Agent.PromptTemplate)
    )
  end
end

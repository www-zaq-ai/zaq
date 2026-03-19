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

  Always returns a plain map:

    * `%{answer: String.t(), confidence: float()}`            — success
    * `%{answer: String.t(), confidence: 0.0, error: true}`   — error
  """

  alias LicenseManager.Paid.KnowledgeGap

  require Logger

  @no_answer_signal "I don't have enough information to answer that question."

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec run(String.t(), keyword()) :: %{answer: String.t(), confidence: float()}
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
          maybe_capture_knowledge_gap(%{
            question: question,
            generated_query: retrieval_result.query,
            history: history
          })

          %{answer: answering_mod(opts).clean_answer(safe_answer), confidence: 0.0}
        else
          %{answer: safe_answer, confidence: confidence_score(answer_result)}
        end

      :ok = hooks.dispatch_after(:after_pipeline_complete, result, ctx)
      result
    else
      {:halt, _payload} ->
        %{answer: "Request was halted by a pipeline hook.", confidence: 0.0, error: true}

      {:error, :prompt_injection} ->
        %{answer: "I can only help with ZAQ-related questions.", confidence: 0.0, error: true}

      {:error, :role_play_attempt} ->
        %{answer: "I can only help with ZAQ-related questions.", confidence: 0.0, error: true}

      {:error, {:leaked, _phrase}} ->
        Logger.warning("[Pipeline] PromptGuard: output leak detected, blocking response")
        %{answer: "I can only help with ZAQ-related questions.", confidence: 0.0, error: true}

      {:error, :no_results, negative_answer} ->
        %{answer: negative_answer, confidence: 0.0}

      {:error, :no_results} ->
        %{
          answer: "I couldn't find relevant information to answer your question.",
          confidence: 0.0
        }

      {:error, reason} ->
        Logger.error("[Pipeline] Error: #{inspect(reason)}")
        %{answer: "Sorry, something went wrong. Please try again.", confidence: 0.0, error: true}
    end
  end

  # ---------------------------------------------------------------------------
  # Knowledge Gap — safe no-op when module not loaded (open-source deployments)
  # ---------------------------------------------------------------------------

  defp maybe_capture_knowledge_gap(params) do
    if function_exported?(LicenseManager.Paid.KnowledgeGap, :capture, 1) do
      KnowledgeGap.capture(params)
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

  defp do_answering(question, query_results, retrieval, _history, opts) do
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
        no_answer_signal: @no_answer_signal
      })

    case node_router(opts).call(:agent, answering_mod(opts), :ask, [system_prompt]) do
      {:ok, %{answer: _, confidence: _} = result} -> {:ok, result}
      {:ok, answer} when is_binary(answer) -> {:ok, %{answer: answer, confidence: %{score: 1.0}}}
      error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp confidence_score(%{confidence: %{score: s}}), do: s
  defp confidence_score(%{confidence: s}) when is_float(s), do: s
  defp confidence_score(_), do: 1.0

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

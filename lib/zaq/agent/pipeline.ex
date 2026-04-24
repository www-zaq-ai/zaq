defmodule Zaq.Agent.Pipeline do
  @moduledoc """
  Shared answering pipeline for all retrieval channels.

  Runs: validate → retrieve → extract → answer → safety check.

  Designed so every retrieval channel (Mattermost, Slack, Teams, chat widget, …) uses
  the same logic without duplication. Adding a new channel requires no changes here.

  ## Hook integration

  The pipeline dispatches the following hook events:

    * `:retrieval`          — sync (`dispatch_sync`); may mutate `%{content: string}` or halt
    * `:retrieval_complete` — async (`dispatch_async`); payload is the retrieval result map
    * `:answering`          — sync (`dispatch_sync`); may mutate the retrieval/extraction payload
    * `:answer_generated`   — async (`dispatch_async`); payload is `%{answer: result}`
    * `:pipeline_complete`  — async (`dispatch_async`); payload is the final result map

  ## Options

    * `:history`            — conversation history map (default: `%{}`)
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
  alias Zaq.Accounts.People
  alias Zaq.Agent.Answering
  alias Zaq.Agent.Answering.Result
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Engine.Telemetry

  @no_answer_signal "I don't have enough information to answer that question."

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec run(Incoming.t(), keyword()) :: Outgoing.t()
  def run(%Incoming{} = incoming, opts \\ []) do
    incoming = pre_do_run(incoming, opts)
    person_id = incoming.person_id

    team_ids =
      case People.get_person(person_id) do
        nil -> []
        person -> person.team_ids || []
      end

    opts = Keyword.merge(opts, person_id: person_id, team_ids: team_ids)
    result = do_run(incoming.content, opts)
    Outgoing.from_pipeline_result(incoming, result)
  end

  @spec pre_do_run(Incoming.t(), keyword()) :: Incoming.t()
  defp pre_do_run(incoming, opts) do
    # Send the start typing event through the router for automatic routing
    node_router(opts).call(:channels, Zaq.Channels.Router, :send_typing, [
      incoming.provider,
      incoming.channel_id
    ])

    incoming
  end

  @spec do_run(String.t(), keyword()) :: map()
  defp do_run(content, opts) do
    history = Keyword.get(opts, :history, %{})
    on_status = Keyword.get(opts, :on_status, fn _stage, _msg -> :ok end)
    ctx = %{trace_id: generate_trace_id(), node: node()}
    hooks = hooks_mod(opts)

    with {:ok, clean_msg} <- prompt_guard(opts).validate(content),
         :ok <- record_message_telemetry(opts),
         {:ok, retrieval_payload} <-
           hooks.dispatch_sync(:retrieval, %{content: clean_msg}, ctx),
         :ok <- on_status.(:retrieving, "ZAQ is searching your knowledge base…"),
         {:ok, retrieval_result} <- do_retrieval(retrieval_payload.content, history, opts),
         :ok <- hooks.dispatch_async(:retrieval_complete, retrieval_result, ctx),
         :ok <- on_status.(:retrieving, retrieval_result.positive_answer),
         {:ok, answering_payload} <-
           hooks.dispatch_sync(:answering, retrieval_result, ctx),
         {:ok, extraction_result} <- do_query_extraction(answering_payload, opts),
         :ok <- on_status.(:answering, "Formulating your answer…"),
         {:ok, answer_result} <-
           do_answering(clean_msg, extraction_result, answering_payload, history, opts),
         {:ok, safe_answer} <- prompt_guard(opts).output_safe?(answer_result.answer) do
      :ok = hooks.dispatch_async(:answer_generated, %{answer: answer_result}, ctx)
      sources = build_sources(extraction_result)

      result =
        if answering_mod(opts).no_answer?(safe_answer) do
          :ok = record_no_answer_telemetry(opts)

          answer_result
          |> result_from_answering(answering_mod(opts).clean_answer(safe_answer), 0.0)
          |> Map.merge(%{
            content: content,
            generated_query: retrieval_result.query,
            history: history,
            sources: sources
          })
        else
          confidence_score = answer_result.confidence_score

          result_from_answering(answer_result, safe_answer, confidence_score)
          |> Map.put(:sources, sources)
        end

      :ok =
        hooks.dispatch_async(
          :pipeline_complete,
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
            content: content,
            generated_query: nil,
            history: history
          })

        :ok = hooks.dispatch_async(:pipeline_complete, Map.put(result, :chunks, []), ctx)
        result

      {:error, :no_results} ->
        :ok = record_no_answer_telemetry(opts)

        result =
          "I couldn't find relevant information to answer your question."
          |> success_result(0.0)
          |> Map.merge(%{
            content: content,
            generated_query: nil,
            history: history
          })

        :ok = hooks.dispatch_async(:pipeline_complete, Map.put(result, :chunks, []), ctx)
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

  defp do_query_extraction(%{query: query, negative_answer: negative_answer}, opts) do
    person_id = Keyword.get(opts, :person_id)
    team_ids = Keyword.get(opts, :team_ids, [])
    skip_permissions = Keyword.get(opts, :skip_permissions, false)

    case node_router(opts).call(
           :ingestion,
           document_processor_mod(opts),
           :query_extraction,
           [query, [person_id: person_id, team_ids: team_ids, skip_permissions: skip_permissions]]
         ) do
      {:ok, results} when results != [] -> {:ok, results}
      {:ok, []} -> {:error, :no_results, negative_answer}
      {:error, _} -> {:error, :no_results, negative_answer}
    end
  end

  defp do_answering(content, query_results, retrieval, history, opts) do
    language = Map.get(retrieval, :language, "en")
    person_id = Keyword.get(opts, :person_id)
    team_ids = Keyword.get(opts, :team_ids, [])

    retrieved_data =
      Enum.map(query_results, fn %{"content" => chunk_content, "source" => source} ->
        %{"content" => chunk_content, "source" => source}
      end)

    system_prompt =
      prompt_template_mod(opts).render("answering", %{
        content: content,
        retrieved_data: Jason.encode!(retrieved_data),
        language: language,
        no_answer_signal: @no_answer_signal,
        has_history: history != %{}
      })

    answer_opts = [
      history: history,
      question: content,
      person_id: person_id,
      team_ids: team_ids,
      telemetry_dimensions: telemetry_dimensions(opts),
      server: Keyword.fetch!(opts, :server)
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

  defp record_message_telemetry(opts) do
    Telemetry.record("qa.message.count", 1, telemetry_dimensions(opts))
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

  @spec build_sources(list()) :: [String.t()]
  defp build_sources(chunks) when is_list(chunks) do
    chunks
    |> Enum.map(&Map.get(&1, "source"))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp build_sources(_), do: []

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

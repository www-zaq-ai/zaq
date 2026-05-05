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
    * `:hooks`              — Hooks module override (default: `Zaq.Hooks`)
    * `:node_router`        — NodeRouter module override
    * `:retrieval`          — Retrieval module override
    * `:document_processor` — DocumentProcessor module override
    * `:answering`          — Answering module override
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
  alias Zaq.Agent.Executor
  alias Zaq.Agent.Tools.SearchKnowledgeBase
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
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

    opts =
      Keyword.merge(opts,
        person_id: person_id,
        team_ids: team_ids,
        source_filter: incoming.content_filter
      )

    result = do_run(incoming, opts)
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

  @spec do_run(Incoming.t(), keyword()) :: map()
  defp do_run(%Incoming{} = incoming, opts) do
    content = incoming.content
    history = Keyword.get(opts, :history, %{})
    ctx = %{trace_id: generate_trace_id(), node: node()}
    hooks = hooks_mod(opts)

    status_context = %{
      session_id: incoming.metadata[:session_id],
      request_id: incoming.metadata[:request_id]
    }

    opts = Keyword.put(opts, :status_context, status_context)

    with :ok <- record_message_telemetry(opts),
         {:ok, retrieval_payload} <-
           hooks.dispatch_sync(:retrieval, %{content: content}, ctx),
         {:ok, retrieval_result} <-
           do_retrieval(retrieval_payload.content, history, opts, incoming),
         :ok <- hooks.dispatch_async(:retrieval_complete, retrieval_result, ctx),
         {:ok, answering_payload} <-
           hooks.dispatch_sync(:answering, retrieval_result, ctx),
         {:ok, extraction_result} <- do_extraction(answering_payload, opts),
         {:ok, answer_result} <-
           do_answering(incoming, content, extraction_result, answering_payload, history, opts) do
      :ok = hooks.dispatch_async(:answer_generated, %{answer: answer_result}, ctx)
      sources = build_sources(extraction_result)
      answer = answer_result.body

      result =
        if answering_mod(opts).no_answer?(answer) do
          :ok = record_no_answer_telemetry(opts)

          answer_result
          |> result_from_answering(answering_mod(opts).clean_answer(answer), 0.0)
          |> Map.merge(%{
            content: content,
            generated_query: retrieval_result.query,
            history: history,
            sources: sources
          })
        else
          confidence_score = answer_result.metadata[:confidence_score]

          result_from_answering(answer_result, answer, confidence_score)
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
        error_result(:halted)

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
        error_result(reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Pipeline steps
  # ---------------------------------------------------------------------------

  defp do_retrieval(clean_msg, history, opts, _incoming) do
    case node_router(opts).call(:agent, retrieval_mod(opts), :ask, [
           clean_msg,
           [history: history]
         ]) do
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

  defp do_extraction(%{query: query} = retrieval_result, opts) do
    negative_answer = Map.get(retrieval_result, :negative_answer)

    context = %{
      person_id: Keyword.get(opts, :person_id),
      team_ids: Keyword.get(opts, :team_ids, []),
      source_filter: Keyword.get(opts, :source_filter),
      skip_permissions: Keyword.get(opts, :skip_permissions, false),
      node_router: node_router(opts),
      document_processor: document_processor_mod(opts),
      status_context: Keyword.get(opts, :status_context)
    }

    case SearchKnowledgeBase.run(%{query: query}, context) do
      {:ok, %{chunks: []}} when is_binary(negative_answer) ->
        {:error, :no_results, negative_answer}

      {:ok, %{chunks: chunks}} ->
        {:ok, chunks}

      {:error, _reason} when is_binary(negative_answer) ->
        {:error, :no_results, negative_answer}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_answering(incoming, content, query_results, retrieval, history, opts) do
    language = Map.get(retrieval, :language, "en")
    person_id = Keyword.get(opts, :person_id)
    team_ids = Keyword.get(opts, :team_ids, [])
    source_filter = Keyword.get(opts, :source_filter)
    skip_permissions = Keyword.get(opts, :skip_permissions, false)

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

    %Outgoing{} =
      outgoing =
      executor_module(opts).run(incoming,
        agent_id: nil,
        scope: Keyword.get(opts, :scope),
        system_prompt: system_prompt,
        question: content,
        person_id: person_id,
        team_ids: team_ids,
        source_filter: source_filter,
        skip_permissions: skip_permissions,
        history: history,
        telemetry_dimensions: telemetry_dimensions(opts),
        node_router: node_router(opts),
        event: Keyword.get(opts, :event)
      )

    {:ok, outgoing}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp telemetry_dimensions(opts) do
    Keyword.get(opts, :telemetry_dimensions, %{})
  end

  defp record_no_answer_telemetry(opts) do
    Telemetry.record("qa.no_answer.count", 1, telemetry_dimensions(opts))
  end

  defp record_message_telemetry(opts) do
    Telemetry.record("qa.message.count", 1, telemetry_dimensions(opts))
  end

  defp result_from_answering(%Outgoing{} = outgoing, answer, confidence_score) do
    %{
      answer: answer,
      confidence_score: confidence_score,
      latency_ms: outgoing.metadata[:latency_ms],
      prompt_tokens: outgoing.metadata[:prompt_tokens],
      completion_tokens: outgoing.metadata[:completion_tokens],
      total_tokens: outgoing.metadata[:total_tokens],
      tool_calls: Map.get(outgoing.metadata, :tool_calls, []),
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

  @generic_error_message "Something went wrong while answering your question. Please try again."

  defp error_result(reason) do
    %{
      answer: @generic_error_message,
      error_reason: reason,
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

  defp executor_module(opts) do
    Keyword.get(
      opts,
      :executor_module,
      Application.get_env(:zaq, :pipeline_executor_module, Executor)
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

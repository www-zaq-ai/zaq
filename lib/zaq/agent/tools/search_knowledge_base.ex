defmodule Zaq.Agent.Tools.SearchKnowledgeBase do
  @moduledoc """
  Agent-facing knowledge search composing independently validated retrieval Actions.

  Prepares language queries once, retrieves the selected legs, fuses only hybrid
  results, then re-ranks the combined candidate set before global count/token
  limiting. Ingestion owns content, permissions and source/language filtering.
  Only direct matches are returned; agents fetch neighboring chunk IDs explicitly.
  """

  use Zaq.Engine.Workflows.Action,
    name: "search_knowledge_base",
    description: """
    Search the knowledge base. search_mode defaults to hybrid (vector and keyword
    search concurrently, then fusion). semantic uses vectors only and needs no
    lexical_terms. keyword uses lexical terms only. For keyword/hybrid supply
    meaningful independent words or phrases, preserving names and identifiers;
    clauses match independently (OR), without splitting the question into filler.
    All modes re-rank when the RAG model is configured. max_total_results defaults
    to 100 globally; the context-token budget may return fewer. Results contain
    chunk_id and previous_chunk_id/next_chunk_id; use get_knowledge_base_chunks
    to fetch additional context rather than assuming surrounding chunks are included.
    """,
    schema:
      Zoi.object(%{
        query: Zoi.string(description: "The original search query") |> Zoi.min(1),
        lexical_terms: Zoi.list(Zoi.string()) |> Zoi.default([]),
        search_mode: Zoi.enum(["semantic", "keyword", "hybrid"]) |> Zoi.optional(),
        max_total_results:
          Zoi.integer(description: "Global maximum, default 100")
          |> Zoi.positive()
          |> Zoi.optional()
      }),
    output_schema:
      Zoi.object(%{
        chunks: Zoi.list(Zoi.map()),
        count: Zoi.integer(),
        errors:
          Zoi.list(
            Zoi.object(%{
              language: Zoi.string(),
              stage: Zoi.enum([:translation, :search]),
              error: Zoi.enum([:translation_failed, :search_failed])
            })
          ),
        partial: Zoi.boolean()
      })

  alias Zaq.Agent.Actions.{
    FuseKnowledgeResults,
    KeywordKnowledgeSearch,
    RerankKnowledgeResults,
    SemanticKnowledgeSearch,
    TranslateKnowledgeQuery
  }

  alias Zaq.Agent.Status
  alias Zaq.Event
  alias Zaq.Ingestion.DocumentProcessor
  alias Zaq.NodeRouter

  require Logger

  def tool_timeout_ms, do: 120_000

  @impl Jido.Action
  def run(params, context) do
    params =
      Map.merge(%{lexical_terms: [], search_mode: "hybrid", max_total_results: 100}, params)

    context =
      Map.put_new(
        context,
        :retrieval_deadline,
        System.monotonic_time(:millisecond) + tool_timeout_ms()
      )

    with :ok <- validate_input(params) do
      bounded_search(params, context)
    end
  end

  defp validate_input(%{query: query, search_mode: mode, max_total_results: maximum} = params) do
    cond do
      not is_binary(query) or String.trim(query) == "" ->
        {:error, :invalid_query}

      mode not in ["semantic", "keyword", "hybrid"] ->
        {:error, :invalid_search_mode}

      not is_integer(maximum) or maximum <= 0 ->
        {:error, :invalid_max_total_results}

      mode != "semantic" and not valid_terms?(params.lexical_terms) ->
        {:error, :invalid_lexical_terms}

      true ->
        :ok
    end
  end

  defp valid_terms?(terms) when is_list(terms) and terms != [],
    do: Enum.all?(terms, &(is_binary(&1) and String.trim(&1) != ""))

  defp valid_terms?(_terms), do: false

  defp bounded_search(params, context) do
    timeout = remaining(context, tool_timeout_ms())

    if timeout <= 0 do
      {:error, "Knowledge base search timed out"}
    else
      task = Task.Supervisor.async(Zaq.TaskSupervisor, fn -> search(params, context) end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _ -> {:error, "Knowledge base search timed out"}
      end
    end
  end

  defp search(params, context) do
    Status.broadcast(
      context[:incoming],
      :retrieving,
      "ZAQ is searching your knowledge base…",
      Map.get(context, :node_router, NodeRouter)
    )

    case dispatch(:list_chunk_languages, %{}, context) do
      {:ok, []} -> {:ok, %{chunks: [], count: 0, errors: [], partial: false}}
      {:ok, languages} when is_list(languages) -> search_languages(params, languages, context)
      {:error, reason} -> {:error, "Knowledge base language discovery failed: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "Knowledge base search error: #{Exception.message(error)}"}
  end

  defp search_languages(params, languages, context) do
    {queries, translation_errors} = translate_languages(params, languages, context)

    {chunks, errors, successful} =
      run_language_searches(params, queries, translation_errors, context)

    if errors != [],
      do: Logger.warning("Knowledge base language searches incomplete: #{inspect(errors)}")

    if successful == 0 and errors != [] do
      {:error, "Knowledge base search failed for all languages: #{inspect(errors)}"}
    else
      merged = merge_chunks(chunks, params.search_mode)

      case execute(RerankKnowledgeResults, %{query: params.query, chunks: merged}, context) do
        {:ok, %{chunks: ranked}} ->
          limit_results(ranked, params.max_total_results, errors, context)

        {:error, _} ->
          {:error, :knowledge_reranking_failed}
      end
    end
  end

  defp limit_results(chunks, maximum, errors, context) do
    case dispatch(
           :limit_knowledge_results,
           %{chunks: chunks, max_total_results: maximum},
           context
         ) do
      {:ok, limited} when is_list(limited) ->
        {:ok, %{chunks: limited, count: length(limited), errors: errors, partial: errors != []}}

      {:error, reason} ->
        {:error, "Knowledge base context limiting failed: #{inspect(reason)}"}
    end
  end

  defp translate_languages(params, languages, context) do
    input =
      Map.take(params, [:query, :lexical_terms, :search_mode]) |> Map.put(:languages, languages)

    case execute(
           TranslateKnowledgeQuery,
           input,
           Map.take(context, [:translation_config, :generation, :retrieval_deadline])
         ) do
      {:ok, %{queries: queries, errors: invalid}} -> {queries, translation_errors(invalid)}
      {:error, _} -> {%{}, translation_errors(languages)}
    end
  end

  defp translation_errors(languages),
    do: Enum.map(languages, &%{language: &1, stage: :translation, error: :translation_failed})

  defp run_language_searches(params, queries, translation_errors, context) do
    sorted = Enum.sort_by(queries, &elem(&1, 0))

    searches =
      Task.Supervisor.async_stream(
        Zaq.TaskSupervisor,
        sorted,
        fn {language, query} -> search_language(params.search_mode, language, query, context) end,
        max_concurrency: 4,
        ordered: true,
        timeout: max(1, remaining(context, 45_000)),
        on_timeout: :kill_task
      )

    sorted
    |> Enum.zip(searches)
    |> Enum.reduce({[], translation_errors, 0}, fn {{language, _}, result},
                                                   {chunks, errors, count} ->
      case result do
        {:ok, {:ok, %{chunks: found}}} ->
          {chunks ++ found, errors, count + 1}

        _ ->
          {chunks, errors ++ [%{language: language, stage: :search, error: :search_failed}],
           count}
      end
    end)
  end

  defp search_language("semantic", language, query, context),
    do:
      execute(
        SemanticKnowledgeSearch,
        %{query: query.semantic_query, language: language},
        context
      )

  defp search_language("keyword", language, query, context),
    do:
      execute(
        KeywordKnowledgeSearch,
        %{lexical_terms: query.lexical_terms, language: language},
        context
      )

  defp search_language("hybrid", language, query, context) do
    legs = [
      {SemanticKnowledgeSearch, %{query: query.semantic_query, language: language}},
      {KeywordKnowledgeSearch, %{lexical_terms: query.lexical_terms, language: language}}
    ]

    results =
      Task.Supervisor.async_stream(
        Zaq.TaskSupervisor,
        legs,
        fn {action, input} -> execute(action, input, context) end,
        max_concurrency: 2,
        ordered: true,
        timeout: max(1, remaining(context, 30_000)),
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    case results do
      [{:ok, {:ok, %{chunks: vector}}}, {:ok, {:ok, %{chunks: lexical}}}] ->
        execute(
          FuseKnowledgeResults,
          %{keyword_chunks: lexical, semantic_chunks: vector},
          context
        )

      _ ->
        {:error, :search_failed}
    end
  end

  defp merge_chunks(chunks, mode) do
    chunks
    |> Enum.with_index()
    |> Enum.sort_by(fn {chunk, index} ->
      {sort_score(chunk, mode), chunk["language"] || "", chunk["document_id"] || 0,
       chunk["section_path"] || [], chunk["chunk_index"] || index}
    end)
    |> Enum.uniq_by(fn {chunk, index} ->
      chunk["chunk_id"] ||
        {chunk["document_id"], chunk["section_path"], chunk["chunk_index"] || index}
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp sort_score(chunk, "semantic"), do: chunk["vector_distance"] || 2.0
  defp sort_score(chunk, "keyword"), do: -(chunk["bm25_score"] || 0.0)
  defp sort_score(chunk, "hybrid"), do: -(chunk["rrf_score"] || 0.0)

  defp remaining(context, maximum),
    do: min(maximum, context.retrieval_deadline - System.monotonic_time(:millisecond))

  # The supervised orchestration tree owns timeouts and cancellation. Validate
  # Actions inline in that tree rather than spawning independently owned Jido
  # timeout workers. Pass only the native operation's trusted context contract.
  defp execute(action, input, context) do
    action_context =
      Map.take(context, [
        :person_id,
        :team_ids,
        :skip_permissions,
        :source_filter,
        :node_router,
        :document_processor,
        :execution_actor,
        :translation_config,
        :generation,
        :reranking_config,
        :reranker,
        :retrieval_deadline
      ])

    Jido.Exec.run(action, input, action_context, timeout: 0, max_retries: 0)
  end

  defp dispatch(action, request, context) do
    router = Map.get(context, :node_router, NodeRouter)

    event =
      Event.new(request, :ingestion,
        actor: context[:execution_actor],
        opts: [
          action: action,
          document_processor: Map.get(context, :document_processor, DocumentProcessor)
        ]
      )

    router.dispatch(event).response
  end
end

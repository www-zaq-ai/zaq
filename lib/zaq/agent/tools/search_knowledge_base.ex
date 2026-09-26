defmodule Zaq.Agent.Tools.SearchKnowledgeBase do
  @moduledoc """
  ReAct tool: searches the ZAQ knowledge base with a refined query.

  Discovers globally indexed languages through the Ingestion role, translates
  the caller-supplied lexical terms once, and searches each language independently. Permission filtering
  stays in Ingestion after candidate retrieval, before results leave the role.
  """

  use Zaq.Engine.Workflows.Action,
    name: "search_knowledge_base",
    output_schema:
      Zoi.object(%{
        chunks: Zoi.list(Zoi.map(), description: "Matching knowledge-base chunks"),
        count: Zoi.integer(description: "Number of chunks returned"),
        errors:
          Zoi.list(
            Zoi.object(%{
              language: Zoi.string(),
              stage: Zoi.enum([:translation, :search]),
              error: Zoi.enum([:translation_failed, :search_failed])
            }),
            description: "Failures for individual detected languages"
          ),
        partial: Zoi.boolean(description: "Some language searches failed")
      }),
    description: """
    Search the ZAQ knowledge base for relevant information.
    Use this when the context provided in the system prompt is insufficient
    to answer the question with confidence. Supply meaningful lexical terms,
    including names and identifiers, rather than splitting the question into words.
    Each supplied term or multiword phrase independently matches (OR search).
    """,
    schema:
      Zoi.object(%{
        query: Zoi.string(description: "The full semantic search query"),
        lexical_terms:
          Zoi.list(
            Zoi.string(),
            description:
              "Meaningful words or multiword phrases for OR lexical search; preserve names and identifiers, omit filler words"
          )
      })

  alias Zaq.Agent.Actions.TranslateKnowledgeQuery
  alias Zaq.Agent.Status
  alias Zaq.Event
  alias Zaq.Ingestion.DocumentProcessor
  alias Zaq.NodeRouter

  require Logger

  @impl Jido.Action

  def run(%{query: query, lexical_terms: terms}, context) do
    Status.broadcast(
      Map.get(context, :incoming),
      :retrieving,
      "ZAQ is searching your knowledge base…",
      Map.get(context, :node_router, NodeRouter)
    )

    person_id = Map.get(context, :person_id)
    team_ids = Map.get(context, :team_ids, [])
    source_filter = Map.get(context, :source_filter)
    node_router_mod = Map.get(context, :node_router, NodeRouter)
    doc_proc_mod = Map.get(context, :document_processor, DocumentProcessor)

    # nil person_id should NEVER grant all permissions.
    # Admin access must be explicitly granted via skip_permissions: true in context.
    # If the query has no identified person and is not explicitly an admin,
    # return only public data (skip_permissions: false, person_id: nil).
    skip_permissions = Map.get(context, :skip_permissions, false)

    opts =
      [
        person_id: person_id,
        team_ids: team_ids,
        skip_permissions: skip_permissions,
        source_filter: source_filter
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    try do
      case dispatch(node_router_mod, :list_chunk_languages, %{}, doc_proc_mod) do
        {:ok, languages} when is_list(languages) ->
          search_languages(query, terms, languages, opts, context, node_router_mod, doc_proc_mod)

        {:error, reason} ->
          {:error, "Knowledge base language discovery failed: #{inspect(reason)}"}
      end
    rescue
      e -> {:error, "Knowledge base search error: #{Exception.message(e)}"}
    end
  end

  defp search_languages(_query, _terms, [], _opts, _context, _router, _processor),
    do: {:ok, %{chunks: [], count: 0, errors: [], partial: false}}

  defp search_languages(query, terms, languages, opts, context, router, processor) do
    {language_queries, translation_errors} =
      translate_languages(query, terms, languages, context)

    {chunks, search_errors, successful} =
      run_language_searches(language_queries, opts, router, processor, translation_errors)

    if search_errors != [] do
      Logger.warning("Knowledge base language searches incomplete: #{inspect(search_errors)}")
    end

    if successful == 0 and search_errors != [] do
      {:error, "Knowledge base search failed for all languages: #{inspect(search_errors)}"}
    else
      merged = merge_chunks(chunks)

      case dispatch(router, :limit_knowledge_results, %{chunks: merged}, processor) do
        {:ok, limited} when is_list(limited) ->
          {:ok,
           %{
             chunks: limited,
             count: length(limited),
             errors: search_errors,
             partial: search_errors != []
           }}

        {:error, reason} ->
          {:error, "Knowledge base context limiting failed: #{inspect(reason)}"}
      end
    end
  end

  defp translate_languages(query, terms, languages, context) do
    case Jido.Exec.run(
           TranslateKnowledgeQuery,
           %{query: query, lexical_terms: terms, languages: languages},
           Map.take(context, [:llm_config, :generation])
         ) do
      {:ok, %{queries: queries, errors: invalid}} ->
        {queries,
         Enum.map(invalid, &%{language: &1, stage: :translation, error: :translation_failed})}

      {:error, _reason} ->
        {%{},
         Enum.map(languages, &%{language: &1, stage: :translation, error: :translation_failed})}
    end
  end

  defp run_language_searches(language_queries, opts, router, processor, translation_errors) do
    searches =
      language_queries
      |> Enum.sort_by(&elem(&1, 0))
      |> Task.async_stream(
        fn {language, %{semantic_query: semantic, lexical_terms: terms}} ->
          try do
            dispatch(
              router,
              :search_knowledge_base,
              %{
                query: semantic,
                access_opts: opts ++ [language: language, unbounded: true, lexical_terms: terms]
              },
              processor
            )
          rescue
            _error in [RuntimeError, ArgumentError] -> {:error, :search_exception}
          end
        end,
        max_concurrency: 4,
        timeout: 45_000,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.to_list()

    language_queries
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.zip(searches)
    |> Enum.reduce({[], translation_errors, 0}, fn {{language, _}, result},
                                                   {chunks, errors, count} ->
      case result do
        {:ok, {:ok, found}} when is_list(found) ->
          {chunks ++ found, errors, count + 1}

        _ ->
          {chunks, errors ++ [%{language: language, stage: :search, error: :search_failed}],
           count}
      end
    end)
  end

  defp merge_chunks(chunks) do
    chunks
    |> Enum.with_index()
    |> Enum.sort_by(fn {chunk, index} ->
      {-(chunk["rrf_score"] || chunk["distance"] || 0.0), chunk["language"] || "",
       chunk["document_id"] || 0, chunk["section_path"] || [], chunk["chunk_index"] || index}
    end)
    |> Enum.uniq_by(fn {chunk, index} ->
      {chunk["document_id"], chunk["section_path"], chunk["chunk_index"] || index}
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp dispatch(router, action, request, processor) do
    event = Event.new(request, :ingestion, opts: [action: action, document_processor: processor])
    router.dispatch(event).response
  end
end

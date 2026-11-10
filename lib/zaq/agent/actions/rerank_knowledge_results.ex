defmodule Zaq.Agent.Actions.RerankKnowledgeResults do
  @moduledoc """
  Reorders authorized knowledge chunks using the configured RAG reranking model.

  No configured selection preserves the input exactly. Configured failures are
  sanitized hard errors. Retrieval scores and original chunk metadata survive;
  provider document echoes never replace trusted content. Denied placeholders
  remain in their original positions and never leave for model inference.

  Failure messages retain only a fixed stage/reason and typed HTTP status.
  Raw provider errors, response bodies and authentication never enter diagnostics.
  """

  use Zaq.Engine.Workflows.Action,
    name: "rerank_knowledge_results",
    description:
      "Re-rank knowledge chunks by configured model relevance, or preserve input when unconfigured",
    schema: Zoi.object(%{query: Zoi.string() |> Zoi.min(1), chunks: Zoi.list(Zoi.map())}),
    output_schema: Zoi.object(%{chunks: Zoi.list(Zoi.map())})

  alias Jido.Action.Error, as: ActionError
  alias Zaq.Agent.ErrorMessage
  alias Zaq.Agent.ProviderSpec
  alias Zaq.System

  @impl Jido.Action
  def run(%{query: query, chunks: chunks}, context) do
    config =
      Map.get_lazy(context, :reranking_config, fn -> System.get_rag_model_config(:reranking) end)

    if is_nil(config.credential_id) and is_nil(config.model) do
      {:ok, %{chunks: chunks}}
    else
      rerank(query, chunks, config, context)
    end
  rescue
    _error -> failure(:runtime, :unexpected_exception)
  end

  defp rerank(query, chunks, config, context) do
    eligible = Enum.filter(chunks, &eligible?/1)

    if eligible == [] do
      {:ok, %{chunks: chunks}}
    else
      with {:runtime, {:ok, model, opts}} <-
             {:runtime, ProviderSpec.operation_runtime(config, :reranking)},
           {:deadline, {:ok, timeout}} <- {:deadline, remaining_timeout(context)},
           {:request, {:ok, response}} <-
             {:request, request(model, opts, query, eligible, timeout, context)},
           {:response, {:ok, ranked}} <- {:response, ranked_chunks(response, eligible)} do
        {:ok, %{chunks: restore_placeholders(chunks, ranked)}}
      else
        {stage, {:error, reason}} -> failure(stage, reason)
        {stage, _unexpected} -> failure(stage, :unexpected_result)
      end
    end
  end

  defp eligible?(chunk), do: is_integer(chunk["chunk_id"]) and is_binary(chunk["content"])

  defp remaining_timeout(context) do
    now = Elixir.System.monotonic_time(:millisecond)
    timeout = Map.get(context, :retrieval_deadline, now + 30_000) - now
    if timeout > 0, do: {:ok, timeout}, else: {:error, :timeout}
  end

  defp request(model, opts, query, chunks, timeout, context) do
    client = Map.get(context, :reranker, ReqLLM)

    opts =
      Keyword.merge(opts,
        query: query,
        documents: Enum.map(chunks, & &1["content"]),
        top_n: length(chunks),
        total_timeout: timeout,
        receive_timeout: min(timeout, 30_000)
      )

    client.rerank(model, opts)
  rescue
    _error -> {:error, :unexpected_exception}
  end

  defp ranked_chunks(%{results: results}, chunks) when is_list(results) do
    expected = MapSet.new(0..(length(chunks) - 1))

    if Enum.all?(results, &valid_result?/1) and length(results) == length(chunks) and
         MapSet.new(results, & &1.index) == expected do
      by_index = chunks |> Enum.with_index() |> Map.new(fn {chunk, index} -> {index, chunk} end)

      ranked =
        results
        |> Enum.sort_by(&{-&1.relevance_score, &1.index})
        |> Enum.map(fn result ->
          Map.put(by_index[result.index], "rerank_score", result.relevance_score)
        end)

      {:ok, ranked}
    else
      {:error, :invalid_response}
    end
  end

  defp ranked_chunks(_response, _chunks), do: {:error, :invalid_response}

  defp valid_result?(%{index: index, relevance_score: score}),
    do: is_integer(index) and is_number(score)

  defp valid_result?(_result), do: false

  defp failure(stage, reason) do
    diagnostic = ErrorMessage.diagnostic_for(reason)
    status = if diagnostic[:http_status], do: " (HTTP #{diagnostic.http_status})", else: ""
    message = "knowledge_reranking_failed: #{stage}/#{diagnostic.reason}#{status}"
    {:error, ActionError.execution_error(message)}
  end

  defp restore_placeholders(chunks, ranked) do
    {restored, []} =
      Enum.map_reduce(chunks, ranked, fn chunk, remaining ->
        if eligible?(chunk) do
          [next | rest] = remaining
          {next, rest}
        else
          {chunk, remaining}
        end
      end)

    restored
  end
end

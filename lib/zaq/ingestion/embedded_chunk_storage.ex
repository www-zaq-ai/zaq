defmodule Zaq.Ingestion.EmbeddedChunkStorage do
  @moduledoc """
  Stores vectors already produced by the embedding provider. Setup and each
  insert have separate transactions so one failed item does not undo others.
  """

  alias Zaq.Contracts.Record
  alias Zaq.Ingestion.{ChunkRefresh, ChunkRefreshSource, DocumentProcessor}

  @max_items 16
  @metadata_keys ~w(section_id section_type section_level position tokens start end figure_title)

  @doc "Defines the shared input contract for the Action and the Ingestion boundary."
  @spec schema() :: Zoi.Type.t()
  def schema do
    chunk =
      Zoi.object(%{
        chunk_index: Zoi.integer() |> Zoi.positive(),
        content: Zoi.string() |> Zoi.min(1) |> Zoi.max(65_536),
        section_path: Zoi.list(Zoi.string()),
        metadata: Zoi.map()
      })

    embedding =
      Zoi.object(%{
        chunk_index: Zoi.integer() |> Zoi.positive(),
        model: Zoi.string(),
        dimension: Zoi.integer(),
        vector: Zoi.list() |> Zoi.max(4000)
      })

    Zoi.object(
      %{
        attempt_id: Zoi.string(description: "Stable UUID for the refresh"),
        record:
          Record.zoi_type(description: "Source Record with signed permissions; required on start")
          |> Zoi.optional(),
        markdown:
          Zoi.string(description: "Converted content; required on start") |> Zoi.optional(),
        items:
          Zoi.list(Zoi.object(%{chunk: chunk, embedding: embedding}))
          |> Zoi.min(1)
          |> Zoi.max(@max_items)
      },
      unrecognized_keys: :error
    )
  end

  @doc "Starts or resumes a source refresh and returns outcomes in input order."
  @spec store(map(), map()) :: {:ok, map()} | {:error, term()}
  def store(input, context) do
    case Zoi.parse(schema(), input) do
      {:ok, params} -> store_validated(params, context)
      {:error, _errors} -> {:error, :invalid_chunk_storage_input}
    end
  end

  defp store_validated(%{attempt_id: attempt_id, items: items} = params, context) do
    with :ok <- validate_indices(items),
         {:ok, _user} <- ChunkRefreshSource.authorize(context[:actor]),
         context <- attach_configuration(context),
         {:ok, document} <- prepare(attempt_id, params[:record], params[:markdown], context) do
      results =
        Enum.map(items, &store_item(&1, attempt_id, context, context.embedding_configuration))

      {:ok, %{document_id: document.id, attempt_id: attempt_id, results: results}}
    end
  end

  defp attach_configuration(context) do
    config = Zaq.System.get_embedding_config()

    Map.put(context, :embedding_configuration, %{model: config.model, dimension: config.dimension})
  end

  defp prepare(id, nil, nil, context), do: ChunkRefresh.resume(id, context)

  defp prepare(id, %Record{} = record, markdown, context) when is_binary(markdown),
    do: ChunkRefresh.start(id, record, markdown, context)

  defp prepare(_id, _record, _markdown, _context), do: {:error, :invalid_refresh_input}

  defp validate_indices(items) do
    indices = Enum.map(items, & &1.chunk.chunk_index)

    if Enum.uniq(indices) == indices, do: :ok, else: {:error, :duplicate_chunk_indices}
  end

  defp store_item(%{chunk: chunk, embedding: embedding}, attempt_id, context, configuration) do
    result =
      ChunkRefresh.insert(attempt_id, chunk.chunk_index, context, fn document ->
        with :ok <- validate_embedding(chunk.chunk_index, embedding, configuration) do
          DocumentProcessor.insert_precomputed_chunk(
            document.id,
            chunk.chunk_index,
            chunk.content,
            chunk.section_path,
            chunk_metadata(chunk.metadata),
            embedding.vector
          )
        end
      end)

    outcome(chunk.chunk_index, result)
  end

  defp chunk_metadata(metadata) do
    metadata
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.take(@metadata_keys)
  end

  defp validate_embedding(index, embedding, config) do
    cond do
      embedding.chunk_index != index -> {:error, :embedding_index_mismatch}
      embedding.model != config.model -> {:error, :embedding_model_mismatch}
      embedding.dimension != config.dimension -> {:error, :dimension_mismatch}
      length(embedding.vector) != config.dimension -> {:error, :dimension_mismatch}
      not Enum.all?(embedding.vector, &halfvec_number?/1) -> {:error, :invalid_vector}
      true -> :ok
    end
  end

  defp halfvec_number?(value), do: is_number(value) and abs(value) <= 65_504

  defp outcome(index, {:ok, status}), do: %{chunk_index: index, status: Atom.to_string(status)}

  defp outcome(index, {:error, reason}) when is_atom(reason),
    do: %{chunk_index: index, status: "error", error: Atom.to_string(reason)}

  defp outcome(index, {:error, _reason}),
    do: %{chunk_index: index, status: "error", error: "chunk_insert_failed"}
end

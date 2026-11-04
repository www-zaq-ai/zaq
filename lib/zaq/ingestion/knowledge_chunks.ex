defmodule Zaq.Ingestion.KnowledgeChunks do
  @moduledoc """
  Materializes exact knowledge chunks with document context and navigation IDs.

  DocumentAccess remains the authority for document grants. Search matches are
  redacted when inaccessible; exact-ID reads return only accessible chunks.
  Adjacency follows persisted document order, independent of retrieval matches,
  sections and languages. Neighbor content is never implicitly fetched.
  """

  import Ecto.Query

  alias Zaq.Ingestion.{Chunk, Document, DocumentAccess}
  alias Zaq.Repo

  @access_denied_message "You don't have access to this chunk."

  @doc "Returns the existing search placeholder for an inaccessible chunk."
  def access_denied_message, do: @access_denied_message

  @doc "Fetches exactly the requested accessible IDs, without search or context limiting."
  def fetch(chunk_ids, access_opts \\ []) do
    if is_list(chunk_ids) and chunk_ids != [] and
         Enum.all?(chunk_ids, &(is_integer(&1) and &1 > 0)) do
      fetch_validated(Enum.uniq(chunk_ids), access_opts)
    else
      {:error, :invalid_chunk_ids}
    end
  end

  defp fetch_validated(ids, access_opts) do
    doc_ids =
      Repo.all(from(c in Chunk, where: c.id in ^ids, select: c.document_id, distinct: true))

    allowed_ids = doc_ids |> permitted_documents(access_opts) |> MapSet.to_list()

    source_condition =
      DocumentAccess.build_source_filter_condition(Keyword.get(access_opts, :source_filter))

    by_id =
      allowed_ids
      |> materialization_query()
      |> where([c], c.id in ^ids)
      |> where(^source_condition)
      |> Repo.all()
      |> Enum.map(&serialize_timestamps/1)
      |> Map.new(&{&1["chunk_id"], &1})

    chunks = Enum.flat_map(ids, fn id -> if by_id[id], do: [by_id[id]], else: [] end)
    unavailable = Enum.reject(ids, &Map.has_key?(by_id, &1))
    {:ok, %{chunks: chunks, count: length(chunks), unavailable_ids: unavailable}}
  end

  @doc "Hydrates only direct retrieval matches, preserving their supplied order."
  def hydrate(matches, access_opts)
  def hydrate([], _access_opts), do: []

  def hydrate(matches, access_opts) do
    matches = Enum.uniq_by(matches, &{&1.document_id, &1.chunk_index})
    doc_ids = matches |> Enum.map(& &1.document_id) |> Enum.uniq()

    predicate =
      Enum.reduce(matches, dynamic(false), fn match, predicate ->
        dynamic(
          [c],
          ^predicate or
            (c.document_id == ^match.document_id and c.chunk_index == ^match.chunk_index)
        )
      end)

    chunks =
      doc_ids
      |> materialization_query()
      |> where(^predicate)
      |> Repo.all()
      |> Map.new(&{{&1["document_id"], &1["chunk_index"]}, &1})

    permitted = permitted_documents(doc_ids, access_opts)

    Enum.flat_map(matches, fn match ->
      case Map.get(chunks, {match.document_id, match.chunk_index}) do
        nil -> []
        chunk -> [chunk |> put_evidence(match) |> authorize(permitted)]
      end
    end)
  end

  # Compute the window before the outer match filter, so sparse retrieval hits
  # never become each other's neighbors. Only IDs, not neighbor content, are read.
  defp materialization_query(doc_ids) do
    neighbors =
      from(c in Chunk,
        where: c.document_id in ^doc_ids,
        windows: [document_order: [partition_by: c.document_id, order_by: [c.chunk_index, c.id]]],
        select: %{
          id: c.id,
          previous_id: over(lag(c.id), :document_order),
          next_id: over(lead(c.id), :document_order)
        }
      )

    from(c in Chunk,
      join: d in Document,
      on: c.document_id == d.id,
      as: :doc,
      join: n in subquery(neighbors),
      on: n.id == c.id,
      select: %{
        "chunk_id" => c.id,
        "previous_chunk_id" => n.previous_id,
        "next_chunk_id" => n.next_id,
        "document_id" => c.document_id,
        "chunk_index" => c.chunk_index,
        "section_path" => c.section_path,
        "content" => c.content,
        "metadata" => c.metadata,
        "language" => c.language,
        "source" => d.source,
        "title" => d.title,
        "watch_status" => d.watch_status,
        "inserted_at" => d.inserted_at,
        "updated_at" => d.updated_at
      }
    )
  end

  defp put_evidence(chunk, match) do
    chunk
    |> serialize_timestamps()
    |> Map.merge(%{
      "rrf_score" => Map.get(match, :rrf_score),
      "bm25_score" => Map.get(match, :bm25_score),
      "vector_distance" => Map.get(match, :vector_distance),
      "retrieval_legs" =>
        Enum.filter(
          [
            if(Map.get(match, :lexical_match), do: "lexical"),
            if(is_number(Map.get(match, :vector_distance)), do: "vector")
          ],
          & &1
        ),
      "direct_match" => true
    })
  end

  defp serialize_timestamps(chunk) do
    Map.new(chunk, fn
      {key, %DateTime{} = timestamp} when key in ["inserted_at", "updated_at"] ->
        {key, DateTime.to_iso8601(timestamp)}

      pair ->
        pair
    end)
  end

  defp permitted_documents(doc_ids, opts) do
    if Keyword.get(opts, :skip_permissions, false) == true do
      MapSet.new(doc_ids)
    else
      doc_ids
      |> Enum.chunk_every(500)
      |> Enum.flat_map(fn ids ->
        DocumentAccess.list_permitted_document_ids(
          Keyword.get(opts, :person_id),
          Keyword.get(opts, :team_ids, []),
          ids
        )
      end)
      |> MapSet.new()
    end
  end

  defp authorize(chunk, permitted) do
    if MapSet.member?(permitted, chunk["document_id"]) do
      chunk
    else
      chunk
      |> Map.drop(
        ~w(chunk_id previous_chunk_id next_chunk_id title watch_status inserted_at updated_at metadata language bm25_score vector_distance retrieval_legs direct_match)
      )
      |> Map.put("content", @access_denied_message)
    end
  end
end

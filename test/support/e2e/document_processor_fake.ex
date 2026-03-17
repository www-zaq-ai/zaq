defmodule Zaq.E2E.DocumentProcessorFake do
  @moduledoc false

  @behaviour Zaq.DocumentProcessorBehaviour

  import Ecto.Query

  alias Zaq.Ingestion.{Chunk, Document, FileExplorer}
  alias Zaq.Repo

  @impl true
  def process_single_file(file_path, role_id \\ nil, shared_role_ids \\ []) do
    with {:ok, content} <- File.read(file_path),
         {:ok, source} <- extract_source(file_path),
         {:ok, document} <- Document.upsert(%{source: source, content: content, role_id: role_id}),
         :ok <- upsert_chunk(document.id, content, role_id, shared_role_ids) do
      {:ok, document}
    end
  end

  def query_extraction(query, role_ids \\ nil) do
    terms = tokenize(query)

    docs =
      role_ids
      |> list_documents_for_roles()
      |> Enum.map(fn doc -> {score_document(doc, terms), doc} end)

    matches =
      docs
      |> Enum.filter(fn {score, _doc} -> score > 0 end)
      |> Enum.sort_by(fn {score, doc} -> {-score, doc.source} end)
      |> Enum.take(8)
      |> Enum.map(fn {_score, doc} -> to_extraction(doc) end)

    fallback =
      docs
      |> Enum.sort_by(fn {_score, doc} -> doc.source end)
      |> Enum.take(3)
      |> Enum.map(fn {_score, doc} -> to_extraction(doc) end)

    {:ok, if(matches == [], do: fallback, else: matches)}
  end

  defp list_documents_for_roles(nil) do
    Repo.all(from(d in Document))
  end

  defp list_documents_for_roles(role_ids) when is_list(role_ids) do
    Repo.all(from(d in Document, where: is_nil(d.role_id) or d.role_id in ^role_ids))
  end

  defp extract_source(file_path) do
    base = FileExplorer.base_path() |> Path.expand()
    expanded = Path.expand(file_path)

    source =
      case String.split(expanded, base <> "/", parts: 2) do
        [_, rel] when rel != "" -> rel
        _ -> Path.basename(file_path)
      end

    {:ok, source}
  end

  defp upsert_chunk(document_id, content, role_id, shared_role_ids) do
    Chunk.delete_by_document(document_id)

    attrs = %{
      document_id: document_id,
      content: String.slice(String.trim(content), 0, 4000),
      chunk_index: 1,
      section_path: [],
      metadata: %{"synthetic" => true},
      role_id: role_id,
      shared_role_ids: shared_role_ids
    }

    case Chunk.create(attrs) do
      {:ok, _chunk} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp tokenize(query) do
    query
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/u, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.uniq()
  end

  defp score_document(_doc, []), do: 0

  defp score_document(doc, terms) do
    source = String.downcase(doc.source || "")
    content = String.downcase(doc.content || "")

    Enum.reduce(terms, 0, fn term, acc ->
      source_bonus = if String.contains?(source, term), do: 4, else: 0
      content_bonus = if String.contains?(content, term), do: 1, else: 0
      acc + source_bonus + content_bonus
    end)
  end

  defp to_extraction(doc) do
    %{
      "content" => compact_content(doc.content),
      "source" => doc.source,
      "rrf_score" => 1.0
    }
  end

  defp compact_content(content) do
    content
    |> to_string()
    |> String.split(~r/\R+/, trim: true)
    |> Enum.take(5)
    |> Enum.join(" ")
    |> String.slice(0, 600)
  end
end

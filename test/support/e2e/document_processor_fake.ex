defmodule Zaq.E2E.DocumentProcessorFake do
  @moduledoc false

  @behaviour Zaq.DocumentProcessorBehaviour

  import Ecto.Query

  alias Zaq.E2E.ProcessorState
  alias Zaq.Ingestion.{Chunk, Document, DocumentAccess}
  alias Zaq.Repo
  alias Zaq.Storage.FileExplorer

  @impl true
  def process_single_file(file_path, opts \\ []) do
    case ProcessorState.check_and_consume() do
      :fail ->
        {:error, "Structural error: simulated e2e failure"}

      :ok ->
        do_process(file_path, opts)
    end
  end

  defp do_process(file_path, opts) do
    with {:ok, content} <- File.read(file_path),
         {:ok, source} <- extract_source(file_path, opts),
         :ok <- maybe_write_temporary_markdown(file_path, source),
         source_metadata = document_metadata(opts),
         {:ok, document} <-
           Document.upsert(%{
             source: source,
             content: content,
             metadata: source_metadata
           }),
         :ok <- upsert_chunk(document.id, content) do
      {:ok, document}
    end
  end

  defp maybe_write_temporary_markdown(file_path, source) do
    if Path.extname(file_path) in [".pdf", ".docx", ".pptx", ".xlsx", ".png", ".jpg", ".jpeg"] do
      File.write(Path.rootname(file_path) <> ".md", "# Converted\n\nGenerated for `#{source}`.\n")
    else
      :ok
    end
  end

  def query_extraction(query, access_opts \\ []) do
    person_id = Keyword.get(access_opts, :person_id)
    team_ids = Keyword.get(access_opts, :team_ids, [])
    skip_permissions = Keyword.get(access_opts, :skip_permissions, false)
    terms = tokenize(query)

    docs =
      Repo.all(from(d in Document))
      |> Enum.map(fn doc -> {score_document(doc, terms), doc} end)

    docs =
      if skip_permissions do
        docs
      else
        filter_by_permissions(docs, person_id, team_ids)
      end

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

  defp extract_source(file_path, opts) do
    case Keyword.get(opts, :source_override) do
      source when is_binary(source) and source != "" -> {:ok, source}
      _ -> extract_source(file_path)
    end
  end

  defp document_metadata(opts), do: Keyword.get(opts, :document_metadata, %{})

  defp upsert_chunk(document_id, content) do
    Chunk.delete_by_document(document_id)

    attrs = %{
      document_id: document_id,
      content: String.slice(String.trim(content), 0, 4000),
      chunk_index: 1,
      section_path: [],
      metadata: %{"synthetic" => true}
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
      "distance" => 1.0
    }
  end

  defp filter_by_permissions(docs, nil, _team_ids), do: docs

  defp filter_by_permissions(docs, person_id, team_ids) do
    doc_ids = Enum.map(docs, fn {_, d} -> d.id end)
    permitted = DocumentAccess.list_permitted_document_ids(person_id, team_ids, doc_ids)
    permitted_set = MapSet.new(permitted)

    Enum.map(docs, fn {score, doc} ->
      if MapSet.member?(permitted_set, doc.id), do: {score, doc}, else: {0, doc}
    end)
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

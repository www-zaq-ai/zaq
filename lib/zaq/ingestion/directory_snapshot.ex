defmodule Zaq.Ingestion.DirectorySnapshot do
  @moduledoc false

  import Ecto.Query

  alias Zaq.Ingestion.{Document, FileExplorer, IngestJob, Sidecar, SourcePath}
  alias Zaq.Repo

  def build(entries, current_volume, current_dir, _current_user) do
    file_entries = Enum.filter(entries, &(&1.type == :file))

    entry_details = build_entry_details(file_entries, current_volume, current_dir)
    documents_by_source = fetch_documents_by_source(entry_details)
    jobs_map = fetch_jobs_map(current_volume, entry_details)

    entry_details =
      attach_doc_and_job_details(entry_details, documents_by_source, jobs_map)

    top_level_details = top_level_details(entry_details)

    {ingestion_map, visible_names} =
      build_ingestion_map(top_level_details)

    dir_entries = Enum.filter(entries, &(&1.type == :directory))
    folder_map = build_folder_map(dir_entries, current_volume, current_dir)

    top_level_entries_by_name =
      Map.new(top_level_details, fn detail -> {detail.entry.name, detail.entry} end)

    %{
      entries: select_visible_entries(entries, top_level_entries_by_name, visible_names),
      ingestion_map: Map.merge(ingestion_map, folder_map)
    }
  end

  defp build_entry_details(file_entries, current_volume, current_dir) do
    Enum.map(file_entries, fn entry ->
      relative_path = Path.join(current_dir, entry.name)
      source_candidates = SourcePath.source_candidates(current_volume, relative_path)

      %{
        entry: entry,
        relative_path: relative_path,
        source_candidates: source_candidates,
        source: List.first(source_candidates)
      }
    end)
  end

  defp fetch_documents_by_source(entry_details) do
    sources = entry_details |> Enum.flat_map(& &1.source_candidates) |> Enum.uniq()

    from(d in Document, where: d.source in ^sources)
    |> Repo.all()
    |> Map.new(fn d -> {d.source, d} end)
  end

  defp fetch_jobs_map(current_volume, entry_details) do
    file_paths = Enum.map(entry_details, & &1.relative_path)

    IngestJob
    |> where([j], j.volume_name == ^current_volume and j.file_path in ^file_paths)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
    |> Enum.reduce(%{}, fn job, acc -> Map.put_new(acc, job.file_path, job.status) end)
  end

  defp attach_doc_and_job_details(entry_details, documents_by_source, jobs_map) do
    Enum.map(entry_details, fn detail ->
      doc = Enum.find_value(detail.source_candidates, &Map.get(documents_by_source, &1))
      source = if doc, do: doc.source, else: detail.source

      Map.merge(detail, %{
        source: source,
        doc: doc,
        job_status: Map.get(jobs_map, detail.relative_path)
      })
    end)
  end

  defp top_level_details(entry_details) do
    entry_by_source = build_entry_by_source(entry_details)

    entry_details
    |> Enum.map(&attach_related_entry(&1, entry_by_source))
    |> hide_related_sidecars()
  end

  defp build_entry_by_source(entry_details) do
    Enum.reduce(entry_details, %{}, fn detail, acc ->
      acc
      |> Map.put(detail.source, detail.entry)
      |> put_candidate_sources(detail.source_candidates, detail.entry)
    end)
  end

  defp put_candidate_sources(acc, source_candidates, entry) do
    Enum.reduce(source_candidates, acc, fn source, map ->
      Map.put_new(map, source, entry)
    end)
  end

  defp attach_related_entry(detail, entry_by_source) do
    related_entry =
      detail.doc
      |> Sidecar.sidecar_source()
      |> then(&Map.get(entry_by_source, &1))
      |> valid_related_entry(detail.entry)

    entry =
      if related_entry do
        Map.put(detail.entry, :related_md, related_entry)
      else
        Map.delete(detail.entry, :related_md)
      end

    Map.put(detail, :entry, entry)
  end

  defp valid_related_entry(nil, _entry), do: nil

  defp valid_related_entry(related_entry, entry) do
    if related_entry.name == entry.name, do: nil, else: related_entry
  end

  defp hide_related_sidecars(entry_details) do
    hidden_sidecar_names =
      Enum.reduce(entry_details, MapSet.new(), fn detail, acc ->
        case Map.get(detail.entry, :related_md) do
          %{name: name} -> MapSet.put(acc, name)
          _ -> acc
        end
      end)

    Enum.reject(entry_details, fn detail ->
      MapSet.member?(hidden_sidecar_names, detail.entry.name)
    end)
  end

  defp build_ingestion_map(top_level_details) do
    doc_ids =
      top_level_details
      |> Enum.map(& &1.doc)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.id)

    permissions_count_map = fetch_permissions_counts(doc_ids)

    Enum.reduce(top_level_details, {%{}, MapSet.new()}, fn detail, {map, visible} ->
      status = resolve_entry_status(detail.entry, detail.doc, permissions_count_map)
      status = Map.put(status, :job_status, detail.job_status)
      map = Map.put(map, detail.entry.name, status)
      visible = MapSet.put(visible, detail.entry.name)
      {map, visible}
    end)
  end

  defp fetch_permissions_counts([]), do: %{}

  defp fetch_permissions_counts(doc_ids) do
    import Ecto.Query

    alias Zaq.Ingestion.Permission

    from(p in Permission,
      where: p.document_id in ^doc_ids,
      group_by: p.document_id,
      select: {p.document_id, count(p.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp resolve_entry_status(_entry, nil, _permissions_count_map) do
    %{ingested_at: nil, stale?: false, permissions_count: 0, can_share?: true}
  end

  defp resolve_entry_status(entry, doc, permissions_count_map) do
    ingested_at = if doc.content, do: doc.updated_at, else: nil
    stale? = not is_nil(ingested_at) and DateTime.compare(entry.modified_at, ingested_at) == :gt
    permissions_count = Map.get(permissions_count_map, doc.id, 0)

    %{
      ingested_at: ingested_at,
      stale?: stale?,
      permissions_count: permissions_count,
      can_share?: true
    }
  end

  defp build_folder_map(dir_entries, current_volume, current_dir) do
    Map.new(dir_entries, fn entry ->
      folder_path = Path.join(current_dir, entry.name)
      prefixes = SourcePath.source_candidates(current_volume, folder_path)

      doc_stats = fetch_folder_doc_stats(prefixes)
      total_size = FileExplorer.folder_size(current_volume, folder_path)

      stats = %{
        type: :directory,
        total_size: total_size,
        file_count: doc_stats.total,
        ingested_count: doc_stats.ingested
      }

      {entry.name, stats}
    end)
  end

  defp fetch_folder_doc_stats(prefixes) do
    conditions =
      prefixes
      |> Enum.map(fn prefix -> dynamic([d], like(d.source, ^"#{prefix}/%")) end)
      |> Enum.reduce(fn cond, acc -> dynamic([d], ^acc or ^cond) end)

    from(d in Document, where: ^conditions, select: not is_nil(d.content))
    |> Repo.all()
    |> Enum.reduce(%{total: 0, ingested: 0}, fn has_content, acc ->
      %{acc | total: acc.total + 1, ingested: acc.ingested + if(has_content, do: 1, else: 0)}
    end)
  end

  defp select_visible_entries(entries, top_level_entries_by_name, visible_names) do
    entries
    |> Enum.reduce([], fn entry, acc ->
      case visible_entry(entry, top_level_entries_by_name, visible_names) do
        nil -> acc
        visible_entry -> [visible_entry | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp visible_entry(%{type: :directory} = entry, _top_level_entries_by_name, _visible_names),
    do: entry

  defp visible_entry(entry, top_level_entries_by_name, visible_names) do
    if MapSet.member?(visible_names, entry.name) do
      Map.get(top_level_entries_by_name, entry.name)
    else
      nil
    end
  end
end

defmodule Zaq.Ingestion.DirectorySnapshot do
  @moduledoc false

  import Ecto.Query

  alias Zaq.Ingestion.{Document, FileExplorer, FolderSetting, IngestJob, Sidecar, SourcePath}
  alias Zaq.Repo

  def build(entries, current_volume, current_dir, _current_user) do
    file_entries = Enum.filter(entries, &(entry_kind(&1) == :file))

    entry_details = build_entry_details(file_entries, current_volume, current_dir)
    documents_by_source = fetch_documents_by_source(entry_details)
    jobs_map = fetch_jobs_map(current_volume, entry_details)

    entry_details =
      attach_doc_and_job_details(entry_details, documents_by_source, jobs_map)

    top_level_details = top_level_details(entry_details)

    {ingestion_map, visible_names} =
      build_ingestion_map(top_level_details)

    dir_entries = Enum.filter(entries, &(entry_kind(&1) == :folder))
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
      relative_path = entry_path(entry, current_dir)
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
    file_paths = entry_details |> Enum.flat_map(&path_variants(&1.relative_path)) |> Enum.uniq()

    IngestJob
    |> where([j], j.volume_name == ^current_volume and j.file_path in ^file_paths)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
    |> Enum.reduce(%{}, fn job, acc ->
      Map.put_new(acc, normalize_job_path(job.file_path), job.status)
    end)
  end

  defp path_variants("./" <> _ = path), do: [path, SourcePath.normalize_relative(path)]
  defp path_variants(path), do: [path, legacy_root_path(path)] |> Enum.uniq()

  defp legacy_root_path(path) when is_binary(path) do
    if String.contains?(path, "/"), do: path, else: "./" <> path
  end

  defp normalize_job_path(path) when is_binary(path), do: SourcePath.normalize_relative(path)

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

    entry = put_related_record(detail.entry, related_entry)

    Map.put(detail, :entry, entry)
  end

  defp valid_related_entry(nil, _entry), do: nil

  defp valid_related_entry(related_entry, entry) do
    if related_entry.name == entry.name, do: nil, else: related_entry
  end

  defp put_related_record(entry, nil) do
    attrs = entry |> record_attributes() |> Map.delete("related_record")
    Map.put(entry, :attributes, attrs)
  end

  defp put_related_record(entry, related_entry) do
    attrs =
      Map.put(record_attributes(entry), "related_record", related_record_payload(related_entry))

    Map.put(entry, :attributes, attrs)
  end

  defp related_record(%{attributes: attrs}) when is_map(attrs),
    do: Map.get(attrs, "related_record")

  defp related_record(_entry), do: nil

  defp related_record_payload(entry) do
    %{
      "name" => entry.name,
      "path" => entry_path(entry, "."),
      "size" => Map.get(entry, :size)
    }
  end

  defp record_attributes(%{attributes: attrs}) when is_map(attrs), do: attrs
  defp record_attributes(_entry), do: %{}

  defp hide_related_sidecars(entry_details) do
    hidden_sidecar_names =
      Enum.reduce(entry_details, MapSet.new(), fn detail, acc ->
        case related_record(detail.entry) do
          %{"name" => name} -> MapSet.put(acc, name)
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

    alias Zaq.Permissions.DocumentPermission, as: Permission

    id_strings = Enum.map(doc_ids, &to_string/1)

    from(p in Permission,
      where: p.resource_type == "document" and p.resource_id in ^id_strings,
      group_by: p.resource_id,
      select: {fragment("?::integer", p.resource_id), count(p.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp resolve_entry_status(_entry, nil, _permissions_count_map) do
    %{ingested_at: nil, stale?: false, permissions_count: 0, is_public: false, can_share?: true}
  end

  defp resolve_entry_status(entry, doc, permissions_count_map) do
    ingested_at = if doc.content, do: doc.updated_at, else: nil
    stale? = not is_nil(ingested_at) and DateTime.compare(entry.modified_at, ingested_at) == :gt
    permissions_count = Map.get(permissions_count_map, doc.id, 0)

    %{
      ingested_at: ingested_at,
      stale?: stale?,
      permissions_count: permissions_count,
      is_public: "public" in doc.tags,
      can_share?: true
    }
  end

  defp build_folder_map(dir_entries, current_volume, current_dir) do
    Map.new(dir_entries, fn entry ->
      folder_path = entry_path(entry, current_dir)
      prefixes = SourcePath.source_candidates(current_volume, folder_path)

      doc_stats = fetch_folder_doc_stats(prefixes)
      total_size = FileExplorer.folder_size(current_volume, folder_path)

      is_public =
        case FolderSetting.get(current_volume, folder_path) do
          nil -> false
          setting -> "public" in setting.tags
        end

      stats = %{
        type: :directory,
        total_size: total_size,
        file_count: doc_stats.total,
        ingested_count: doc_stats.ingested,
        is_public: is_public
      }

      {entry.name, stats}
    end)
  end

  defp fetch_folder_doc_stats(prefixes) do
    conditions = Document.source_prefix_conditions(prefixes)

    from(d in Document,
      where: ^conditions,
      where: fragment("(? ->> 'source_document_source') IS NULL", d.metadata),
      select: not is_nil(d.content)
    )
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

  defp visible_entry(entry, top_level_entries_by_name, visible_names) do
    cond do
      entry_kind(entry) == :folder ->
        entry

      MapSet.member?(visible_names, entry.name) ->
        Map.get(top_level_entries_by_name, entry.name)

      true ->
        nil
    end
  end

  defp entry_kind(%{kind: :folder}), do: :folder
  defp entry_kind(%{kind: "folder"}), do: :folder
  defp entry_kind(%{type: :directory}), do: :folder
  defp entry_kind(_), do: :file

  defp entry_path(%{path: path}, _current_dir) when is_binary(path), do: path
  defp entry_path(entry, current_dir), do: Path.join(current_dir, entry.name)
end

defmodule Zaq.Ingestion.RenameService do
  @moduledoc false

  require Logger

  import Ecto.Query

  alias Ecto.Multi
  alias Zaq.Ingestion.{Document, FileExplorer, Sidecar, SourcePath}
  alias Zaq.Repo

  def rename_entry(volume_name, old_path, new_path, volumes \\ nil) do
    volumes = volumes || FileExplorer.list_volumes()

    with {:ok, %{type: type}} <- FileExplorer.file_info(volume_name, old_path) do
      rename_by_type(type, volume_name, old_path, new_path, volumes)
    end
  end

  defp rename_by_type(:directory, volume_name, old_path, new_path, volumes) do
    old_relative = SourcePath.normalize_relative(old_path)
    new_relative = SourcePath.normalize_relative(new_path)

    rename_ops = [%{volume: volume_name, old_relative: old_relative, new_relative: new_relative}]
    db_multi = build_directory_multi(volume_name, old_relative, new_relative, volumes)

    rename_with_saga(rename_ops, db_multi)
  end

  defp rename_by_type(:file, volume_name, old_path, new_path, volumes) do
    old_relative = SourcePath.normalize_relative(old_path)
    new_relative = SourcePath.normalize_relative(new_path)

    if old_relative == new_relative do
      :ok
    else
      plan = build_plan(volume_name, old_relative, new_relative, volumes)
      db_multi = build_file_multi(plan.source_update, plan.sidecar_update)
      rename_with_saga(plan.rename_ops, db_multi)
    end
  end

  defp rename_with_saga(rename_ops, db_multi) do
    saga =
      Enum.reduce(rename_ops, Sage.new(), fn op, sage ->
        Sage.run(
          sage,
          {:fs, op.volume, op.old_relative},
          fn _, _ -> fs_rename_step(op.volume, op.old_relative, op.new_relative) end,
          fn _, _, _ -> fs_compensate_step(op.volume, op.old_relative, op.new_relative) end
        )
      end)
      |> Sage.run(:db, fn _, _ ->
        case Repo.transaction(db_multi) do
          {:ok, _} -> {:ok, :ok}
          {:error, _, reason, _} -> {:error, reason}
        end
      end)

    case Sage.execute(saga) do
      {:ok, _, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fs_rename_step(volume, old_relative, new_relative) do
    case FileExplorer.rename(volume, old_relative, new_relative) do
      :ok -> {:ok, :ok}
      {:error, _} = err -> err
    end
  end

  defp fs_compensate_step(volume, old_relative, new_relative) do
    case FileExplorer.rename(volume, new_relative, old_relative) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Saga FS compensation failed for #{old_relative}: #{inspect(reason)}")
        :ok
    end
  end

  defp build_directory_multi(volume_name, old_relative, new_relative, volumes) do
    all_prefixes =
      SourcePath.source_candidates(volume_name, old_relative) ++
        legacy_directory_prefixes(volume_name, old_relative, volumes)

    all_prefixes
    |> Enum.uniq()
    |> Enum.reduce(Multi.new(), fn old_prefix, multi ->
      new_prefix = SourcePath.remap_source(old_prefix, volume_name, new_relative)

      multi
      |> Multi.update_all(
        {:source, old_prefix},
        Document.rename_source_prefix_query(old_prefix, new_prefix),
        []
      )
      |> Multi.update_all(
        {:sidecar_source, old_prefix},
        Document.rename_metadata_key_query("sidecar_source", old_prefix, new_prefix),
        []
      )
      |> Multi.update_all(
        {:source_document_source, old_prefix},
        Document.rename_metadata_key_query("source_document_source", old_prefix, new_prefix),
        []
      )
    end)
    |> Multi.run(:sync_stranded_legacy, fn repo, _ ->
      sync_stranded_legacy_docs(repo, volume_name, new_relative, volumes)
    end)
  end

  # Legacy sources were stored as "volume_name/<absolute_path_without_leading_slash>"
  # when absolute_to_source was broken. Compute that prefix so the prefix-based
  # rename query also migrates rows created with the SAME name as the current rename.
  defp legacy_directory_prefixes(volume_name, old_relative, volumes),
    do: SourcePath.legacy_folder_prefixes(volume_name, old_relative, volumes)

  # Handles legacy docs that are "stranded" because a previous rename (before this
  # fix existed) moved the folder on disk but left their absolute-path sources
  # pointing to the old folder name.  After the FS rename completes, any legacy doc
  # whose embedded file now exists under new_relative on disk belongs to this folder
  # and must be rewritten to the canonical relative-path format.
  defp sync_stranded_legacy_docs(repo, volume_name, new_relative, volumes) do
    case Map.get(volumes, volume_name) do
      nil ->
        {:ok, 0}

      base_path ->
        expanded_base = Path.expand(base_path)
        base_without_slash = String.trim_leading(expanded_base, "/")
        volume_legacy_prefix = volume_name <> "/" <> base_without_slash <> "/"

        legacy_docs =
          from(d in Document, where: like(d.source, ^"#{volume_legacy_prefix}%"))
          |> repo.all()

        count =
          Enum.count(legacy_docs, fn doc ->
            embedded =
              doc.source
              |> String.replace_prefix(volume_legacy_prefix, "")
              |> strip_legacy_prefix(base_without_slash)

            migrate_stranded_doc(repo, doc, embedded, expanded_base, volume_name, new_relative)
          end)

        {:ok, count}
    end
  end

  defp migrate_stranded_doc(repo, doc, embedded, expanded_base, volume_name, new_relative) do
    case String.split(embedded, "/", parts: 2) do
      [_historical_folder, rest] ->
        new_abs = Path.join([expanded_base, new_relative, rest])

        if File.exists?(new_abs) do
          new_source = volume_name <> "/" <> new_relative <> "/" <> rest
          upsert_migrated_doc(repo, doc, new_source)
          true
        else
          false
        end

      _ ->
        false
    end
  end

  defp upsert_migrated_doc(repo, doc, new_source) do
    case repo.get_by(Document, source: new_source) do
      nil -> doc |> Ecto.Changeset.change(source: new_source) |> repo.update!()
      _exists -> repo.delete!(doc)
    end
  end

  defp build_file_multi(source_update, sidecar_update) do
    multi = Multi.new()

    multi =
      case source_update do
        %{document: document} = update when not is_nil(document) ->
          changeset =
            Document.changeset(document, %{
              source: update.new_source,
              metadata: update.new_metadata
            })

          Multi.update(multi, :source_doc, changeset)

        _ ->
          multi
      end

    case sidecar_update do
      %{document: document} = update when not is_nil(document) ->
        changeset =
          Document.changeset(document, %{
            source: update.new_source,
            metadata: update.new_metadata
          })

        Multi.update(multi, :sidecar_doc, changeset)

      _ ->
        multi
    end
  end

  defp build_plan(volume_name, old_relative, new_relative, volumes) do
    source_doc = find_source_document(volume_name, old_relative)
    source_update = build_source_update(source_doc, volume_name, new_relative)

    {source_update, sidecar_update} =
      build_sidecar_updates(
        source_doc,
        source_update,
        volume_name,
        old_relative,
        new_relative,
        volumes
      )

    rename_ops =
      [%{volume: volume_name, old_relative: old_relative, new_relative: new_relative}]
      |> maybe_add_sidecar_op(sidecar_update)
      |> Enum.reject(fn op -> op.old_relative == op.new_relative end)
      |> Enum.uniq_by(fn op -> {op.volume, op.old_relative, op.new_relative} end)

    %{rename_ops: rename_ops, source_update: source_update, sidecar_update: sidecar_update}
  end

  defp find_source_document(volume_name, old_relative) do
    volume_name
    |> SourcePath.source_candidates(old_relative)
    |> Enum.find_value(&Document.get_by_source/1)
  end

  defp build_source_update(nil, _volume_name, _new_relative), do: nil

  defp build_source_update(source_doc, volume_name, new_relative) do
    %{
      document: source_doc,
      new_source: SourcePath.remap_source(source_doc.source, volume_name, new_relative),
      new_metadata: source_doc.metadata
    }
  end

  defp build_sidecar_updates(
         nil,
         source_update,
         _volume_name,
         _old_relative,
         _new_relative,
         _volumes
       ),
       do: {source_update, nil}

  defp build_sidecar_updates(
         source_doc,
         source_update,
         volume_name,
         old_relative,
         new_relative,
         volumes
       ) do
    case Sidecar.sidecar_source(source_doc) do
      nil ->
        {source_update, nil}

      sidecar_source ->
        {sidecar_volume, sidecar_old_relative} =
          SourcePath.split_source(sidecar_source, volume_name, volumes)

        sidecar_new_relative =
          Sidecar.retarget_relative_path(old_relative, sidecar_old_relative, new_relative)

        sidecar_new_source =
          SourcePath.remap_source(sidecar_source, sidecar_volume, sidecar_new_relative)

        sidecar_doc = Document.get_by_source(sidecar_source)
        source_new_source = source_update.new_source

        source_update = %{
          source_update
          | new_metadata: Sidecar.put_sidecar_source(source_doc.metadata, sidecar_new_source)
        }

        sidecar_update = %{
          volume: sidecar_volume,
          old_relative: sidecar_old_relative,
          new_relative: sidecar_new_relative,
          document: sidecar_doc,
          new_source: sidecar_new_source,
          new_metadata:
            if(sidecar_doc,
              do: Sidecar.put_source_document_source(sidecar_doc.metadata, source_new_source),
              else: nil
            )
        }

        {source_update, sidecar_update}
    end
  end

  defp maybe_add_sidecar_op(rename_ops, nil), do: rename_ops

  defp maybe_add_sidecar_op(rename_ops, sidecar_update) do
    rename_ops ++
      [
        %{
          volume: sidecar_update.volume,
          old_relative: sidecar_update.old_relative,
          new_relative: sidecar_update.new_relative
        }
      ]
  end

  # Strips repeated absolute-path prefix layers from a legacy embedded path.
  # Handles the case where the source was double-corrupted (e.g. corrupt script
  # ran on an already-corrupted source), leaving the base path embedded twice.
  defp strip_legacy_prefix(path, base_without_slash) do
    prefix = base_without_slash <> "/"

    if String.starts_with?(path, prefix) do
      path |> String.replace_prefix(prefix, "") |> strip_legacy_prefix(base_without_slash)
    else
      path
    end
  end

  defp maybe_update_document(multi, _name, nil), do: multi
  defp maybe_update_document(multi, _name, %{document: nil}), do: multi

  defp maybe_update_document(multi, name, %{document: document} = update) do
    changeset =
      Document.changeset(document, %{
        source: update.new_source,
        metadata: update.new_metadata
      })

    Multi.update(multi, name, changeset)
  end
end

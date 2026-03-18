defmodule Zaq.Ingestion.RenameService do
  @moduledoc false

  alias Ecto.Multi
  alias Zaq.Ingestion.{Document, FileExplorer, Sidecar, SourcePath}
  alias Zaq.Repo

  def rename_entry(volume_name, old_path, new_path, volumes \\ nil) do
    volumes = volumes || FileExplorer.list_volumes()

    with {:ok, %{type: type}} <- FileExplorer.file_info(volume_name, old_path) do
      rename_by_type(type, volume_name, old_path, new_path, volumes)
    end
  end

  defp rename_by_type(:directory, volume_name, old_path, new_path, _volumes) do
    FileExplorer.rename(volume_name, old_path, new_path)
  end

  defp rename_by_type(:file, volume_name, old_path, new_path, volumes) do
    old_relative = SourcePath.normalize_relative(old_path)
    new_relative = SourcePath.normalize_relative(new_path)

    if old_relative == new_relative do
      :ok
    else
      plan = build_plan(volume_name, old_relative, new_relative, volumes)

      with {:ok, _renamed_ops} <- execute_rename_ops(plan.rename_ops),
           :ok <- persist_document_updates(plan.source_update, plan.sidecar_update) do
        :ok
      else
        {:error, reason} = error ->
          rollback_rename_ops(Enum.reverse(plan.rename_ops), reason)
          error

        {:error, reason, renamed_ops} = error ->
          rollback_rename_ops(renamed_ops, reason)
          error
      end
      |> normalize_error()
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

        sidecar_update =
          %{
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
    [
      %{
        volume: sidecar_update.volume,
        old_relative: sidecar_update.old_relative,
        new_relative: sidecar_update.new_relative
      }
      | rename_ops
    ]
  end

  defp execute_rename_ops(rename_ops) do
    Enum.reduce_while(rename_ops, {:ok, []}, fn op, {:ok, applied} ->
      case FileExplorer.rename(op.volume, op.old_relative, op.new_relative) do
        :ok -> {:cont, {:ok, [op | applied]}}
        {:error, reason} -> {:halt, {:error, reason, applied}}
      end
    end)
  end

  defp persist_document_updates(source_update, sidecar_update) do
    Multi.new()
    |> maybe_update_document(:source_doc, source_update)
    |> maybe_update_document(:sidecar_doc, sidecar_update)
    |> Repo.transaction()
    |> case do
      {:ok, _changes} -> :ok
      {:error, _step, reason, _changes} -> {:error, reason}
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

  defp rollback_rename_ops(rename_ops, reason) do
    Enum.each(rename_ops, fn op ->
      _ = FileExplorer.rename(op.volume, op.new_relative, op.old_relative)
    end)

    {:error, reason}
  end

  defp normalize_error(:ok), do: :ok
  defp normalize_error({:error, reason}), do: {:error, reason}
  defp normalize_error({:error, reason, _ops}), do: {:error, reason}
end

defmodule Zaq.Ingestion.Labels do
  @moduledoc """
  Category definitions and manual resource assignments owned by Ingestion.

  Definitions have typed targets. Resource decisions use separate FK-backed tables;
  a manual exclusion is retained even when no inclusion previously existed.
  Automatic controls are unavailable until the processing pipeline is implemented.
  """
  import Ecto.Query

  alias Zaq.Ingestion.Labels.{
    Access,
    ChunkAssignment,
    DocumentAssignment,
    Label,
    ResourceLabels,
    Target
  }

  alias Zaq.Repo

  defdelegate value_summaries(ids, actor),
    to: Zaq.Ingestion.Labels.ValueManagement,
    as: :summaries

  defdelegate list_values(id, query, offset, actor),
    to: Zaq.Ingestion.Labels.ValueManagement,
    as: :values

  defdelegate value_resources(id, value, offset, actor),
    to: Zaq.Ingestion.Labels.ValueManagement,
    as: :resources

  @spec list(map() | nil, non_neg_integer(), String.t()) :: {:ok, list()} | {:error, atom()}
  def list(actor, offset \\ 0, query \\ "")

  def list(actor, offset, query) when is_integer(offset) and offset >= 0 and is_binary(query) do
    with {:ok, _} <- Access.user(actor) do
      query = query |> String.trim() |> String.normalize(:nfc) |> String.slice(0, 200)

      {:ok,
       Repo.all(
         from l in Label,
           where:
             fragment("strpos(lower(?), lower(?)) > 0", l.name, ^query) or
               fragment("strpos(lower(?), lower(?)) > 0", l.description, ^query),
           order_by: l.normalized_name,
           limit: 51,
           offset: ^offset,
           preload: :targets
       )}
    end
  end

  def list(_, _, _), do: {:error, :invalid_request}

  @doc "Creates/updates a definition and target settings atomically, with expected revision on edits."
  @spec save_definition(map(), map() | nil) :: {:ok, struct()} | {:error, term()}
  def save_definition(attrs, actor) when is_map(attrs) do
    with :ok <- Access.manager(actor),
         :ok <- valid_identity(attrs),
         :ok <- manual_only(attrs),
         {:ok, types} <- target_types(attrs) do
      Repo.transaction(fn ->
        label = lock_definition(attrs)
        check_version!(label, attr(attrs, :expected_version))
        check_removed_targets!(label, types)
        saved = persist!(Label.changeset(label, attrs))
        sync_targets(saved, types)
        Repo.preload(saved, :targets, force: true)
      end)
    end
  end

  def save_definition(_, _), do: {:error, :invalid_request}

  @doc "Returns the definition revision and active document/chunk usage for deletion confirmation."
  @spec deletion_preview(pos_integer(), map() | nil) :: {:ok, map()} | {:error, term()}
  def deletion_preview(id, actor) when is_integer(id) and id > 0 do
    with :ok <- Access.manager(actor) do
      Repo.transaction(fn -> deletion_snapshot(lock_definition(%{id: id})) end)
    end
  end

  def deletion_preview(_, _), do: {:error, :invalid_request}

  @doc "Deletes a confirmed definition and its assignments atomically; resource rows are preserved."
  @spec delete_definition(map(), map() | nil) :: {:ok, map()} | {:error, term()}
  def delete_definition(attrs, actor) when is_map(attrs) do
    with :ok <- Access.manager(actor),
         :ok <- valid_deletion(attrs) do
      Repo.transaction(fn -> delete_confirmed!(attrs) end)
    end
  end

  def delete_definition(_, _), do: {:error, :invalid_request}

  @doc "Previews up to one catalog page of labels under ordered definition locks."
  def bulk_deletion_preview(ids, actor) do
    with :ok <- Access.manager(actor), :ok <- valid_batch_ids(ids) do
      Repo.transaction(fn ->
        ids
        |> Enum.sort()
        |> Enum.map(&lock_definition(%{id: &1}))
        |> Enum.map(&deletion_snapshot/1)
      end)
    end
  end

  @doc "Deletes a confirmed batch atomically; any stale label or usage rolls back the batch."
  def delete_definitions(requests, actor) when is_list(requests) do
    with :ok <- Access.manager(actor),
         true <- Enum.all?(requests, &(is_map(&1) and valid_deletion(&1) == :ok)),
         :ok <- valid_batch_ids(Enum.map(requests, &attr(&1, :id))) do
      Repo.transaction(fn ->
        requests |> Enum.sort_by(&attr(&1, :id)) |> Enum.map(&delete_confirmed!/1)
      end)
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  def delete_definitions(_, _), do: {:error, :invalid_request}

  defp valid_batch_ids(ids) when is_list(ids) and length(ids) in 1..50 do
    if Enum.all?(ids, &(is_integer(&1) and &1 > 0)) and length(Enum.uniq(ids)) == length(ids),
      do: :ok,
      else: {:error, :invalid_request}
  end

  defp valid_batch_ids(_), do: {:error, :invalid_request}

  defp delete_confirmed!(attrs) do
    label = lock_definition(attrs)
    check_version!(label, attr(attrs, :expected_version))
    check_deletion_usage!(label, attr(attrs, :expected_usage))
    delete_assignments(label.id)
    label |> Repo.delete() |> unwrap!()
    %{id: label.id}
  end

  defp check_deletion_usage!(label, expected_usage) do
    snapshot = deletion_snapshot(label)

    unless snapshot.usage.documents == attr(expected_usage, :documents) and
             snapshot.usage.chunks == attr(expected_usage, :chunks) do
      Repo.rollback({:usage_changed, snapshot})
    end
  end

  defp delete_assignments(label_id) do
    for schema <- [DocumentAssignment, ChunkAssignment] do
      Repo.delete_all(from a in schema, where: a.label_id == ^label_id)
    end
  end

  defp valid_deletion(attrs) do
    usage = attr(attrs, :expected_usage)

    if is_integer(attr(attrs, :id)) and attr(attrs, :id) > 0 and
         is_integer(attr(attrs, :expected_version)) and attr(attrs, :expected_version) > 0 and
         is_map(usage) and
         Enum.all?([:documents, :chunks], &(is_integer(attr(usage, &1)) and attr(usage, &1) >= 0)),
       do: :ok,
       else: {:error, :invalid_request}
  end

  defp deletion_snapshot(label) do
    %{
      id: label.id,
      name: label.name,
      expected_version: label.lock_version,
      usage: %{
        documents:
          Repo.aggregate(
            from(a in DocumentAssignment, where: a.label_id == ^label.id and a.selected),
            :count
          ),
        chunks:
          Repo.aggregate(
            from(a in ChunkAssignment, where: a.label_id == ^label.id and a.selected),
            :count
          )
      }
    }
  end

  @spec resource_editor(map(), map() | nil) :: {:ok, map()} | {:error, term()}
  defdelegate resource_editor(resource, actor), to: ResourceLabels, as: :editor

  @spec edit_resource(map(), list(), map() | nil) :: {:ok, map()} | {:error, term()}
  defdelegate edit_resource(resource, edits, actor), to: ResourceLabels, as: :edit

  @doc "Returns permitted existing assignment values for the value picker."
  defdelegate value_suggestions(resource, label_id, query, actor), to: ResourceLabels

  @spec document_chips(list(), map() | nil) :: {:ok, map()} | {:error, term()}
  defdelegate document_chips(sources, actor), to: ResourceLabels

  defp manual_only(attrs) do
    flags = [:automatic, :automatic_document, :automatic_chunk]

    if Enum.any?(flags, &(attr(attrs, &1) not in [nil, false, "false"])),
      do: {:error, :automation_unavailable},
      else: :ok
  end

  defp valid_identity(attrs) do
    case attr(attrs, :id) do
      nil -> :ok
      id when is_integer(id) and id > 0 -> :ok
      _ -> {:error, :invalid_request}
    end
  end

  defp target_types(attrs) do
    case attr(attrs, :targets) do
      types when is_list(types) and types != [] ->
        if Enum.all?(types, &(&1 in ["document", "chunk"])),
          do: {:ok, Enum.uniq(types)},
          else: {:error, :invalid_targets}

      _ ->
        {:error, :invalid_targets}
    end
  end

  defp lock_definition(attrs) do
    case attr(attrs, :id) do
      nil ->
        %Label{}

      id ->
        Repo.one(from l in Label, where: l.id == ^id, lock: "FOR UPDATE") ||
          Repo.rollback(:not_found)
    end
  end

  defp check_version!(%Label{id: nil}, _), do: :ok
  defp check_version!(%Label{lock_version: version}, version), do: :ok
  defp check_version!(_, _), do: Repo.rollback(:stale)

  defp check_removed_targets!(%Label{id: nil}, _), do: :ok

  defp check_removed_targets!(label, types) do
    Enum.each([{"document", DocumentAssignment}, {"chunk", ChunkAssignment}], fn {type, schema} ->
      if type not in types and Repo.exists?(from a in schema, where: a.label_id == ^label.id),
        do: Repo.rollback(:target_in_use)
    end)
  end

  defp persist!(%{data: %{id: nil}} = changeset), do: insert!(changeset)

  defp persist!(changeset) do
    changeset |> Ecto.Changeset.optimistic_lock(:lock_version) |> Repo.update() |> unwrap!()
  end

  defp insert!(changeset), do: changeset |> Repo.insert() |> unwrap!()
  defp unwrap!({:ok, record}), do: record
  defp unwrap!({:error, error}), do: Repo.rollback(error)

  defp sync_targets(label, types) do
    Repo.delete_all(
      from t in Target, where: t.label_id == ^label.id and t.resource_type not in ^types
    )

    existing = Repo.all(from t in Target, where: t.label_id == ^label.id, select: t.resource_type)

    for type <- types -- existing,
        do: insert!(Target.changeset(%Target{label_id: label.id}, type))
  end

  defp attr(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  @doc "Builds a document-ID subquery matching selected label assignments."
  @spec matching_document_ids([pos_integer()], term()) :: Ecto.Query.t()
  def matching_document_ids(ids, match) do
    assignments =
      from a in DocumentAssignment,
        where: a.selected and a.label_id in ^ids,
        group_by: a.document_id,
        select: a.document_id

    assignments =
      if match == {:ok, "all"},
        do: from(a in assignments, having: count(a.label_id, :distinct) == ^length(ids)),
        else: assignments

    assignments
  end

  @doc "Builds a document-ID subquery matching normalized selected label/value pairs."
  @spec matching_document_value_ids([{pos_integer(), term()}], term()) :: Ecto.Query.t()
  def matching_document_value_ids(pairs, match) do
    condition =
      Enum.reduce(pairs, dynamic(false), fn {id, value}, condition ->
        pair =
          if is_nil(value),
            do: dynamic([a], a.label_id == ^id and is_nil(a.value)),
            else: dynamic([a], a.label_id == ^id and a.value == ^value)

        dynamic(^condition or ^pair)
      end)

    assignments =
      from a in DocumentAssignment,
        where: a.selected,
        where: ^condition,
        group_by: a.document_id,
        select: a.document_id

    assignments =
      if match == {:ok, "all"},
        do: from(a in assignments, having: count(a.label_id, :distinct) == ^length(pairs)),
        else: assignments

    assignments
  end
end

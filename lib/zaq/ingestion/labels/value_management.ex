defmodule Zaq.Ingestion.Labels.ValueManagement do
  @moduledoc """
  Resource-scoped label value discovery and bulk correction.

  Values are derived from readable assignments, including pending configurations.
  There is no independent value catalog. Bulk edits target at most 50 explicit
  resource/version pairs and reuse ResourceLabels.edit/4 within one transaction,
  skipping the editor projection that bulk consumers do not use.
  All parent documents are locked in ID order before any definition is locked.
  """
  import Ecto.Query
  alias Zaq.Ingestion.{Chunk, Document}

  alias Zaq.Ingestion.Labels.{
    Access,
    Assignment,
    AssignmentValue,
    ResourceLabels
  }

  alias Zaq.Repo

  @doc "Counts distinct assigned values, pending configurations and readable resources for a catalog page."
  def summaries(ids, actor) when is_list(ids) and length(ids) <= 50 do
    with {:ok, user} <- Access.user(actor),
         true <- Enum.all?(ids, &(is_integer(&1) and &1 > 0)) do
      groups =
        from a in subquery(assignments(ids, actor, user)),
          group_by: [a.label_id, a.state, a.value],
          select: %{label_id: a.label_id, total: count()}

      rows =
        Repo.all(
          from g in subquery(groups),
            group_by: g.label_id,
            select: {g.label_id, %{values: count(), resources: type(sum(g.total), :integer)}}
        )

      {:ok, Map.new(rows)}
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  def summaries(_, _), do: {:error, :invalid_request}

  @doc "Returns up to 51 value/state groups, filtered by a literal substring of their display text."
  def values(label_id, query, offset, actor)
      when is_integer(label_id) and label_id > 0 and is_binary(query) and is_integer(offset) and
             offset >= 0 do
    with {:ok, user} <- Access.user(actor) do
      query = query |> String.slice(0, 200) |> String.trim() |> String.normalize(:nfc)

      rows =
        from a in subquery(assignments([label_id], actor, user, query)),
          group_by: [a.state, a.value],
          order_by: [asc_nulls_first: a.value],
          offset: ^offset,
          limit: 51,
          select: %{
            value: a.value,
            state: a.state,
            documents: filter(count(), a.type == "document"),
            chunks: filter(count(), a.type == "chunk")
          }

      {:ok, Repo.all(rows)}
    end
  end

  def values(_, _, _, _), do: {:error, :invalid_request}

  @doc "Returns a page of readable resources with an exact value, their revision and update capability."
  def resources(label_id, value, offset, actor)
      when is_integer(label_id) and label_id > 0 and is_integer(offset) and offset >= 0 do
    with {:ok, user} <- Access.user(actor),
         true <- AssignmentValue.valid?(value) do
      query = from(a in subquery(assignments([label_id], actor, user)))

      query =
        case AssignmentValue.normalize(value) do
          nil -> where(query, [a], is_nil(a.value))
          value -> where(query, [a], a.value == ^value)
        end

      {:ok,
       Repo.all(
         from a in query, order_by: [a.document_id, a.type, a.id], offset: ^offset, limit: 51
       )}
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  def resources(_, _, _, _), do: {:error, :invalid_request}

  @doc "Atomically replaces typed values on explicit assigned/pending resources; keeps the label applied."
  def update(label_id, resources, value, actor) do
    with {:ok, _user} <- Access.user(actor),
         :ok <- validate_batch(label_id, resources),
         true <- AssignmentValue.valid?(value) do
      Repo.transaction(fn ->
        resolved = Enum.map(resources, &resolve!/1)
        document_ids = resolved |> Enum.map(& &1.document.id) |> Enum.uniq() |> Enum.sort()

        Repo.all(
          from d in Document,
            where: d.id in ^document_ids,
            order_by: d.id,
            select: d.id,
            lock: "FOR UPDATE"
        )

        Enum.each(Enum.zip(resources, resolved), &update_assignment!(&1, label_id, value, actor))

        length(resources)
      end)
    else
      false -> {:error, :invalid_value}
      error -> error
    end
  end

  defp validate_batch(label_id, resources)
       when is_integer(label_id) and label_id > 0 and is_list(resources) and
              length(resources) in 1..50 do
    valid? = Enum.all?(resources, &valid_resource?/1)

    if valid? and length(Enum.uniq_by(resources, &{&1.type, &1.id})) == length(resources),
      do: :ok,
      else: {:error, :invalid_request}
  end

  defp validate_batch(_, _), do: {:error, :invalid_request}

  defp valid_resource?(%{type: type, id: id, expected_version: version}),
    do:
      type in ["document", "chunk"] and is_integer(id) and id > 0 and is_integer(version) and
        version > 0

  defp valid_resource?(_), do: false

  defp update_assignment!({request, resource}, label_id, value, actor) do
    # Discovery requires read rights; check again in case access was revoked.
    case Access.resource(actor, resource.document, :read) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    case Repo.get_by(Assignment,
           resource_type: resource.type,
           resource_id: to_string(resource.id),
           label_id: label_id
         ) do
      %{state: state, lock_version: version}
      when state in [:assigned, :pending] and version == request.expected_version ->
        :ok

      _ ->
        Repo.rollback(:stale)
    end

    edit = %{
      label_id: label_id,
      operation: "add",
      value: value,
      expected_version: request.expected_version
    }

    case ResourceLabels.edit(%{type: resource.type, id: resource.id}, [edit], actor,
           return_projection: false
         ) do
      {:ok, :ok} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp resolve!(resource) do
    case ResourceLabels.resolve(resource) do
      {:ok, resolved} -> resolved
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp assignments(ids, actor, user, search \\ nil) do
    readable = Access.document_ids_query(actor, user)
    writable = Access.document_ids_query(actor, user, :update)
    matching = Assignment.search_values(Assignment, search)

    documents =
      from a in matching,
        join: d in Document,
        on: d.id == a.document_id,
        where:
          a.resource_type == "document" and a.state in [:assigned, :pending] and
            a.label_id in ^ids and d.id in subquery(readable),
        select: %{
          label_id: a.label_id,
          value: a.value,
          state: a.state,
          type: type(^"document", :string),
          id: d.id,
          document_id: d.id,
          title: d.title,
          source: d.source,
          chunk_index: type(^nil, :integer),
          expected_version: a.lock_version,
          editable?: d.id in subquery(writable)
        }

    if Chunk.table_exists?() do
      chunks =
        from a in matching,
          join: c in Chunk,
          on: c.id == a.chunk_id,
          join: d in Document,
          on: d.id == c.document_id,
          where:
            a.resource_type == "chunk" and a.state in [:assigned, :pending] and a.label_id in ^ids and
              d.id in subquery(readable),
          select: %{
            label_id: a.label_id,
            value: a.value,
            state: a.state,
            type: type(^"chunk", :string),
            id: c.id,
            document_id: d.id,
            title: d.title,
            source: d.source,
            chunk_index: c.chunk_index,
            expected_version: a.lock_version,
            editable?: d.id in subquery(writable)
          }

      union_all(documents, ^chunks)
    else
      documents
    end
  end
end

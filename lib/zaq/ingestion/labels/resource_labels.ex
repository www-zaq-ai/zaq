defmodule Zaq.Ingestion.Labels.ResourceLabels do
  @moduledoc """
  Authorized assignment projections and atomic manual decisions.

  Writers lock document → sorted definitions → chunk → assignment. Document locks
  serialize first assignments as well as updates; exclusions participate in target
  removal guards. Chunk identity is rechecked after locking its parent document.
  """
  import Ecto.Query
  alias Zaq.Accounts.People
  alias Zaq.Ingestion.{Chunk, Document}

  alias Zaq.Ingestion.Labels.{
    Access,
    AssignmentValue,
    ChunkAssignment,
    DocumentAssignment,
    Label,
    Target
  }

  alias Zaq.Permissions
  alias Zaq.Repo

  @spec resolve(map()) :: {:ok, map()} | {:error, atom()}
  def resolve(%{type: "document", id: id}) when is_integer(id) and id > 0 do
    case Repo.one(
           from d in Document, where: d.id == ^id, select: struct(d, [:id, :title, :source])
         ) do
      nil ->
        {:error, :not_found}

      doc ->
        {:ok,
         %{type: "document", id: id, document: doc, schema: DocumentAssignment, key: :document_id}}
    end
  end

  def resolve(%{type: "chunk", id: id}) when is_integer(id) and id > 0 do
    if Chunk.table_exists?(), do: resolve_chunk(id), else: {:error, :not_found}
  end

  def resolve(_), do: {:error, :invalid_resource}

  defp resolve_chunk(id) do
    case Repo.one(
           from c in Chunk,
             join: d in Document,
             on: d.id == c.document_id,
             where: c.id == ^id,
             select: %{document: struct(d, [:id, :title, :source])}
         ) do
      nil ->
        {:error, :not_found}

      chunk ->
        {:ok,
         %{
           type: "chunk",
           id: id,
           document: chunk.document,
           schema: ChunkAssignment,
           key: :chunk_id
         }}
    end
  end

  @spec editor(map(), map() | nil) :: {:ok, map()} | {:error, atom()}
  def editor(resource, actor) do
    with {:ok, _} <- Access.user(actor),
         {:ok, resource} <- resolve(resource),
         :ok <- Access.resource(actor, resource.document, :read) do
      {:ok, projection(resource, Access.resource(actor, resource.document, :update) == :ok)}
    end
  end

  @doc """
  Applies versioned assignment edits atomically and returns the editor projection.

  Bulk consumers can pass `return_projection: false` to return `{:ok, :ok}` without
  loading unused editor data. Authorization and locking are unchanged.
  """
  @spec edit(map(), list(), map() | nil) :: {:ok, map()} | {:error, term()}
  @spec edit(map(), list(), map() | nil, keyword()) :: {:ok, map() | :ok} | {:error, term()}
  def edit(resource, edits, actor, opts \\ []) do
    with {:ok, _} <- Access.user(actor),
         {:ok, resource} <- resolve(resource),
         :ok <- Access.resource(actor, resource.document, :update),
         :ok <- validate_edits(edits) do
      Repo.transaction(fn ->
        Repo.one(
          from d in Document,
            where: d.id == ^resource.document.id,
            select: d.id,
            lock: "FOR UPDATE"
        ) ||
          Repo.rollback(:not_found)

        # Revalidate permissions after acquiring the serialization lock.
        authorize_write!(actor, resource.document)

        definitions = lock_definitions!(edits)
        lock_chunk!(resource)
        Enum.each(edits, &apply_edit!(resource, &1, definitions))
        edit_result(resource, Keyword.get(opts, :return_projection, true))
      end)
    end
  end

  defp edit_result(resource, true), do: projection(resource, true)
  defp edit_result(_resource, false), do: :ok

  defp authorize_write!(actor, document) do
    case Access.resource(actor, document, :update) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @spec document_chips(list(), map() | nil) :: {:ok, map()} | {:error, atom()}
  def document_chips(sources, actor) when is_list(sources) and length(sources) <= 500 do
    with {:ok, user} <- Access.user(actor) do
      documents =
        Repo.all(
          from d in Document, where: d.source in ^sources, select: struct(d, [:id, :source])
        )

      visible = visible_documents(documents, actor, user)
      ids = Enum.map(visible, & &1.id)

      chips =
        Repo.all(DocumentAssignment.selected_labels_query(ids))
        |> Enum.map(fn
          {id, %{value: nil} = chip} -> {id, Map.delete(chip, :value)}
          entry -> entry
        end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

      {:ok,
       Map.new(visible, &{&1.source, %{document_id: &1.id, chips: Map.get(chips, &1.id, [])}})}
    end
  end

  def document_chips(_, _), do: {:error, :invalid_request}

  @doc "Suggests existing values only from resources readable by the current BO actor."
  def value_suggestions(resource, label_id, query, actor)
      when is_integer(label_id) and label_id > 0 and is_binary(query) do
    with {:ok, user} <- Access.user(actor),
         {:ok, resource} <- resolve(resource),
         :ok <- Access.resource(actor, resource.document, :read) do
      query = query |> String.slice(0, 200) |> String.trim() |> String.downcase()
      documents = Access.document_ids_query(actor, user)
      values = value_candidates(label_id, query, documents)

      {:ok,
       Repo.all(
         from v in subquery(values), distinct: true, order_by: v.value, limit: 20, select: v.value
       )}
    end
  end

  def value_suggestions(_, _, _, _), do: {:error, :invalid_request}

  defp value_candidates(label_id, query, documents) do
    document_values =
      from a in matching_values(DocumentAssignment, label_id, query),
        where: a.document_id in subquery(documents),
        select: %{value: a.value}

    if Chunk.table_exists?() do
      chunk_values =
        from a in matching_values(ChunkAssignment, label_id, query),
          join: c in Chunk,
          on: c.id == a.chunk_id,
          where: c.document_id in subquery(documents),
          select: %{value: a.value}

      union(document_values, ^chunk_values)
    else
      document_values
    end
  end

  defp matching_values(schema, label_id, query) do
    from a in schema,
      where: a.label_id == ^label_id and a.selected and not is_nil(a.value),
      where: fragment("strpos(lower(?), ?) > 0", a.value, ^query)
  end

  defp visible_documents(documents, _actor, %{role: %{name: "super_admin"}}), do: documents

  defp visible_documents(documents, actor, _user) do
    person = actor[:person_id] && People.get_person(actor[:person_id])

    documents
    |> Enum.map(&{&1, []})
    |> Permissions.list_effective_many(access: Permissions.access(person, :read))
    |> Enum.filter(fn {_document, grants} -> grants != [] end)
    |> Enum.map(&elem(&1, 0))
  end

  defp projection(resource, editable?) do
    labels =
      Repo.all(
        from l in Label,
          join: t in Target,
          on: t.label_id == l.id,
          where: t.resource_type == ^resource.type,
          order_by: l.normalized_name
      )

    assignments =
      Repo.all(from a in resource.schema, where: field(a, ^resource.key) == ^resource.id)
      |> Map.new(&{&1.label_id, &1})

    rows =
      Enum.map(labels, fn label ->
        assignment = Map.get(assignments, label.id)

        %{
          id: label.id,
          name: label.name,
          description: label.description,
          selected: assignment != nil and assignment.selected,
          value: if(assignment, do: assignment.value, else: nil),
          expected_version: if(assignment, do: assignment.lock_version, else: 0)
        }
      end)

    %{
      resource: %{type: resource.type, id: resource.id},
      title: resource.document.title,
      editable?: editable?,
      labels: rows
    }
  end

  defp validate_edits(edits) when is_list(edits) and length(edits) <= 200 do
    valid? = Enum.all?(edits, &valid_edit?/1)

    cond do
      not valid? ->
        {:error, :invalid_edits}

      Enum.any?(edits, &(not AssignmentValue.valid?(Map.get(&1, :value)))) ->
        {:error, :invalid_value}

      length(Enum.uniq_by(edits, & &1.label_id)) != length(edits) ->
        {:error, :invalid_edits}

      Enum.any?(edits, &(&1.operation == "reset_automatic")) ->
        {:error, :automation_unavailable}

      true ->
        :ok
    end
  end

  defp validate_edits(_), do: {:error, :invalid_edits}

  defp valid_edit?(%{label_id: id, operation: op, expected_version: version}) do
    is_integer(id) and id >= 0 and op in ["add", "remove", "reset_automatic"] and
      is_integer(version) and version >= 0
  end

  defp valid_edit?(_), do: false

  defp lock_definitions!(edits) do
    ids = Enum.map(edits, & &1.label_id) |> Enum.sort()
    labels = Repo.all(from l in Label, where: l.id in ^ids, order_by: l.id, lock: "FOR UPDATE")
    if length(labels) != length(ids), do: Repo.rollback(:not_found)
    Map.new(labels, &{&1.id, &1})
  end

  defp lock_chunk!(%{type: "document"}), do: :ok

  defp lock_chunk!(resource) do
    Repo.one(
      from c in Chunk,
        where: c.id == ^resource.id and c.document_id == ^resource.document.id,
        select: c.id,
        lock: "FOR UPDATE"
    ) || Repo.rollback(:not_found)
  end

  defp apply_edit!(resource, edit, definitions) do
    label = Map.fetch!(definitions, edit.label_id)

    unless Repo.exists?(
             from t in Target,
               where: t.label_id == ^label.id and t.resource_type == ^resource.type
           ),
           do: Repo.rollback(:target_mismatch)

    existing =
      Repo.one(
        from a in resource.schema,
          where: field(a, ^resource.key) == ^resource.id and a.label_id == ^label.id,
          lock: "FOR UPDATE"
      )

    actual_version = if(existing, do: existing.lock_version, else: 0)
    if actual_version != edit.expected_version, do: Repo.rollback(:stale)

    assignment =
      existing || struct(resource.schema, [{resource.key, resource.id}, {:label_id, label.id}])

    changeset =
      resource.schema.decision_changeset(
        assignment,
        edit.operation == "add",
        Map.get(edit, :value, :unchanged)
      )

    case save_assignment(changeset, existing) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp save_assignment(changeset, nil), do: Repo.insert(changeset)

  defp save_assignment(changeset, _existing),
    do: Repo.update(Ecto.Changeset.optimistic_lock(changeset, :lock_version))
end

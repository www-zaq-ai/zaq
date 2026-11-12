defmodule Zaq.Ingestion.Labels.ResourceLabels do
  @moduledoc """
  Authorized assignment projections and atomic manual decisions.

  Writers lock document → sorted definitions → chunk → assignment. Document locks
  serialize first assignments as well as updates; exclusions participate in target
  removal guards. Chunk identity is rechecked after locking its parent document.
  """
  import Ecto.Query
  alias Zaq.Accounts.People
  alias Zaq.Contracts.SourceRecordContext
  alias Zaq.Ingestion.{Chunk, Document, ExternalSource}

  alias Zaq.Ingestion.Labels.{
    Access,
    Assignment,
    AssignmentValue,
    Label
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
        {:ok, %{type: "document", id: id, document: doc}}
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
           document: chunk.document
         }}
    end
  end

  @doc """
  Returns typed decisions after BO authorization.

  SourceLabels may supply an already-authorized `source_context` in internal opts;
  it owns fresh source read authority and capability checks. The Labels facade
  never accepts this option for ordinary document/chunk selectors or from request
  fields. This path projects missing source identities without persisting them.
  """
  @spec editor(map(), map() | nil, keyword()) :: {:ok, map()} | {:error, atom()}
  def editor(resource, actor, opts \\ []) do
    source_context = Keyword.get(opts, :source_context)

    with {:ok, _} <- Access.user(actor),
         {:ok, resource} <- editor_resource(resource, source_context),
         :ok <- editor_read_access(actor, resource, source_context) do
      {:ok,
       projection(
         resource,
         is_nil(source_context) and Access.resource(actor, resource.document, :update) == :ok
       )}
    end
  end

  defp editor_resource(%{type: "document"}, %SourceRecordContext{} = context) do
    source = ExternalSource.source(context.record)

    document =
      Document.get_by_source(source) || %Document{source: source, title: context.record.name}

    {:ok, %{type: "document", id: document.id, document: document, source_context: context}}
  end

  defp editor_resource(resource, nil), do: resolve(resource)
  defp editor_resource(_, _), do: {:error, :invalid_resource}

  defp editor_read_access(_actor, _resource, %SourceRecordContext{}), do: :ok

  defp editor_read_access(actor, resource, nil),
    do: Access.resource(actor, resource.document, :read)

  @doc """
  Applies versioned assignment edits atomically and returns the editor projection.

  Bulk consumers can pass `return_projection: false` to return `{:ok, :ok}` without
  loading unused editor data. Authorization and locking are unchanged.
  """
  @spec edit(map(), list(), map() | nil) :: {:ok, map()} | {:error, term()}
  @spec edit(map(), list(), map() | nil, keyword()) :: {:ok, map() | :ok} | {:error, term()}
  def edit(resource, edits, actor, opts \\ []) do
    return_projection? = Keyword.get(opts, :return_projection, true)

    with {:ok, _} <- Access.user(actor),
         {:ok, resource} <- resolve(resource),
         :ok <- Access.resource(actor, resource.document, :update),
         :ok <- projection_read_access(actor, resource.document, return_projection?),
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
        authorize_write!(actor, resource.document, return_projection?)

        definitions = lock_definitions!(edits)
        lock_chunk!(resource)
        Enum.each(edits, &apply_edit!(resource, &1, definitions, actor))

        edit_result(
          Map.put(resource, :source_context, Keyword.get(opts, :source_context)),
          return_projection?
        )
      end)
    end
  end

  defp edit_result(resource, true), do: projection(resource, true)
  defp edit_result(_resource, false), do: :ok

  defp projection_read_access(actor, document, true), do: Access.resource(actor, document, :read)
  defp projection_read_access(_actor, _document, false), do: :ok

  defp authorize_write!(actor, document, return_projection?) do
    with :ok <- Access.resource(actor, document, :update),
         :ok <- projection_read_access(actor, document, return_projection?) do
      :ok
    else
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
        Repo.all(Assignment.selected_labels_query(ids))
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
      from a in matching_values(label_id, query),
        where: a.resource_type == "document" and a.document_id in subquery(documents),
        select: %{value: a.value}

    if Chunk.table_exists?() do
      chunk_values =
        from a in matching_values(label_id, query),
          join: c in Chunk,
          on: a.resource_type == "chunk" and c.id == a.chunk_id,
          where: c.document_id in subquery(documents),
          select: %{value: a.value}

      union(document_values, ^chunk_values)
    else
      document_values
    end
  end

  defp matching_values(label_id, query) do
    from(a in Assignment, where: a.label_id == ^label_id and a.state == :assigned)
    |> Assignment.search_values(query)
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
          where: ^resource.type in l.resources,
          order_by: l.normalized_name
      )

    assignments =
      Repo.all(
        from a in Assignment,
          where: a.resource_type == ^resource.type and a.resource_id == ^to_string(resource.id)
      )
      |> Map.new(&{&1.label_id, &1})

    rows =
      Enum.map(labels, fn label ->
        assignment = Map.get(assignments, label.id)

        %{
          id: label.id,
          name: label.name,
          description: label.description,
          value_type: label.value_type,
          value_config: label.value_config,
          assignment_type: label.assignment_type,
          threshold: label.threshold,
          selected: assignment != nil and assignment.state in [:assigned, :pending],
          state: if(assignment, do: assignment.state, else: nil),
          origin: if(assignment, do: assignment.origin, else: nil),
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

  defp apply_edit!(resource, edit, definitions, actor) do
    label = Map.fetch!(definitions, edit.label_id)
    validate_target!(resource, label, edit.operation)

    existing =
      Repo.one(
        from a in Assignment,
          where:
            a.resource_type == ^resource.type and a.resource_id == ^to_string(resource.id) and
              a.label_id == ^label.id,
          lock: "FOR UPDATE"
      )

    actual_version = if(existing, do: existing.lock_version, else: 0)
    if actual_version != edit.expected_version, do: Repo.rollback(:stale)

    assignment =
      existing ||
        %Assignment{
          resource_type: resource.type,
          resource_id: to_string(resource.id),
          label_id: label.id
        }

    changeset =
      Assignment.decision_changeset(
        assignment,
        label,
        edit.operation,
        Map.get(edit, :value, :unchanged)
      )
      |> Ecto.Changeset.change(
        metadata: Map.put(assignment.metadata, "updated_by_user_id", actor.user_id)
      )

    persist_assignment!(changeset, existing)
  end

  defp validate_target!(resource, label, operation) do
    unless resource.type in label.resources, do: Repo.rollback(:target_mismatch)

    if operation == "reset_automatic" and label.assignment_type != "automatic",
      do: Repo.rollback(:automation_unavailable)
  end

  defp persist_assignment!(%{valid?: false}, _existing), do: Repo.rollback(:invalid_value)

  defp persist_assignment!(changeset, existing) do
    case save_assignment(changeset, existing) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp save_assignment(changeset, nil), do: Repo.insert(changeset)

  defp save_assignment(changeset, _existing),
    do: Repo.update(Ecto.Changeset.optimistic_lock(changeset, :lock_version))
end

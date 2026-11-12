defmodule Zaq.Ingestion.ResourceQuery do
  @moduledoc """
  Ingestion-owned metadata queries for indexed documents and label definitions.

  The role API supplies trusted execution context separately from query input.
  Descriptors are a static allowlist, shared with tool discovery at compile time;
  all authorization, filtering, counts, paging and projections execute here.
  """
  import Ecto.Query
  import Zaq.Resources.QuerySupport
  alias Zaq.Ingestion.Document
  alias Zaq.Ingestion.Labels.Assignment
  alias Zaq.Repo
  alias Zaq.Resources.QuerySupport

  @resources [
    %{
      key: "label",
      module: Zaq.Ingestion.Labels.Label,
      public?: false,
      fields:
        ~w(id name description resources resource_types value_type value_config assignment_type threshold inserted_at updated_at)a,
      search_fields: ~w(name description)a,
      filter_fields: ~w(name)a,
      sort_fields: ~w(id name inserted_at updated_at)a,
      default_sort: :name,
      max_limit: 100
    },
    %{
      key: "document",
      module: Zaq.Ingestion.Document,
      public?: false,
      fields: ~w(id title source content_type labels inserted_at updated_at)a,
      search_fields: ~w(title source)a,
      filter_fields: ~w(source content_type label_ids label_values label_match)a,
      sort_fields: ~w(id title source inserted_at updated_at)a,
      default_sort: :title,
      max_limit: 100
    }
  ]

  @doc "Static discovery metadata; does not perform database reads."
  @spec descriptors() :: [map()]
  def descriptors, do: @resources

  @doc "Executes a document or label query using only the owning role's allowlist."
  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  def run(%{resource_type: type} = params, context) do
    with {:ok, descriptor} <- descriptor(type),
         :ok <- validate_requested_fields(descriptor, params),
         :ok <- validate_filter_fields(descriptor, params),
         :ok <- validate_document_filters(descriptor, params),
         :ok <- validate_sort_field(descriptor, params) do
      if present?(Map.get(params, :id)),
        do: get_resource(descriptor, params, context),
        else: list_resources(descriptor, params, context)
    end
  end

  def run(_, _), do: {:error, :invalid_request}

  defp descriptor(type) do
    case Enum.find(@resources, &(&1.key == type)) do
      nil -> {:error, {:unknown_resource_type, type}}
      descriptor -> {:ok, descriptor}
    end
  end

  defp authorized_resource_query(%{key: "label", module: module}, context) do
    if skip_permissions?(context) do
      {:ok, from(row in module)}
    else
      {:ok, descriptor} = descriptor("document")
      {:ok, documents} = QuerySupport.authorized_query(descriptor, context)

      label_ids =
        from a in Assignment,
          join: d in subquery(documents),
          on: d.id == a.document_id,
          where: a.resource_type == "document" and a.state in [:assigned, :pending],
          select: a.label_id

      {:ok, from(row in module, where: row.id in subquery(label_ids))}
    end
  end

  defp authorized_resource_query(descriptor, context),
    do: QuerySupport.authorized_query(descriptor, context)

  defp get_resource(descriptor, params, context) do
    with {:ok, query} <- authorized_resource_query(descriptor, context) do
      id = Map.fetch!(params, :id)
      authorized = where(query, [row], row.id == ^id)
      fields = requested_fields(descriptor, params)

      resource =
        authorized
        |> filter_get_query(descriptor, params)
        |> project_resource_fields(descriptor, fields)
        |> Repo.one()

      case resource do
        nil -> missing_resource(descriptor, params, authorized)
        resource -> render_get_resource(resource, descriptor, params, fields)
      end
    end
  end

  defp filter_get_query(query, %{key: "document"} = descriptor, params) do
    query
    |> apply_search(descriptor, Map.get(params, :query))
    |> apply_filters(descriptor, Map.get(params, :filters, %{}))
  end

  defp filter_get_query(query, _descriptor, _params), do: query

  defp missing_resource(descriptor, params, authorized) do
    cond do
      descriptor.key == "document" and Repo.exists?(authorized) ->
        get_response(descriptor, params, nil)

      resource_exists?(descriptor, Map.fetch!(params, :id)) ->
        {:error, :unauthorized}

      true ->
        get_response(descriptor, params, nil)
    end
  end

  defp render_get_resource(resource, descriptor, params, fields) do
    resource
    |> preload_for_fields(descriptor, fields)
    |> serialize(descriptor, fields)
    |> then(&get_response(descriptor, params, &1))
  end

  defp list_resources(descriptor, params, context) do
    with {:ok, query} <- authorized_resource_query(descriptor, context) do
      page_limit = page_limit(params, descriptor)
      page_offset = page_offset(params)
      fields = requested_fields(descriptor, params)

      filtered_query =
        query
        |> apply_search(descriptor, Map.get(params, :query))
        |> apply_filters(descriptor, Map.get(params, :filters, %{}))

      total_count = count(filtered_query)

      resources =
        filtered_query
        |> apply_sort(descriptor, params)
        |> limit(^page_limit)
        |> offset(^page_offset)
        |> project_resource_fields(descriptor, fields)
        |> Repo.all()
        |> preload_for_fields(descriptor, fields)
        |> Enum.map(&serialize(&1, descriptor, fields))

      {:ok,
       base_response(descriptor, params, %{
         resources: resources,
         found: resources != [],
         count: length(resources),
         total_count: total_count,
         limit: page_limit,
         offset: page_offset
       })}
    end
  end

  defp resource_exists?(%{module: module}, id),
    do: Repo.exists?(from row in module, where: row.id == ^id)

  defp validate_document_filters(%{key: "document"}, params),
    do: Document.validate_label_filters(Map.get(params, :filters, %{}))

  defp validate_document_filters(_descriptor, _params), do: :ok

  defp apply_search(query, descriptor, value) when is_binary(value) and value != "" do
    pattern = "%#{escape_like(String.trim(value))}%"

    condition =
      descriptor.search_fields
      |> Enum.map(&dynamic([row], ilike(field(row, ^&1), ^pattern)))
      |> Enum.reduce(fn condition, acc -> dynamic(^acc or ^condition) end)

    from row in query, where: ^condition
  end

  defp apply_search(query, _descriptor, _value), do: query

  defp apply_filters(query, %{key: "document"} = descriptor, filters) when is_map(filters) do
    ordinary_filters =
      Map.drop(filters, [
        "label_ids",
        "label_values",
        "label_match",
        :label_ids,
        :label_values,
        :label_match
      ])

    query
    |> Document.filter_by_labels(filters)
    |> apply_exact_filters(descriptor, ordinary_filters)
  end

  defp apply_filters(query, descriptor, filters) when is_map(filters),
    do: apply_exact_filters(query, descriptor, filters)

  defp apply_filters(query, _descriptor, _filters), do: query

  defp apply_exact_filters(query, descriptor, filters) do
    Enum.reduce(filters, query, fn {field_name, value}, acc ->
      field = field_atom!(descriptor.filter_fields, field_name)
      apply_filter(acc, field, value)
    end)
  end

  defp apply_filter(query, field, value),
    do: from(row in query, where: field(row, ^field) == ^value)

  defp apply_sort(query, descriptor, params) do
    field =
      field_atom!(descriptor.sort_fields, Map.get(params, :sort_by) || descriptor.default_sort)

    direction = if Map.get(params, :sort_dir) == "desc", do: :desc, else: :asc

    query = order_by(query, [row], [{^direction, field(row, ^field)}])

    if descriptor.key in ["document", "label"] and field != :id,
      do: order_by(query, [row], asc: row.id),
      else: query
  end

  defp count(query) do
    query
    |> exclude(:order_by)
    |> Repo.aggregate(:count, :id)
  end

  defp preload_for_fields(resources, %{key: "label"}, _fields), do: resources

  defp preload_for_fields(resources, %{key: "document"}, fields) when is_list(resources) do
    if :labels in fields do
      labels =
        resources
        |> Enum.map(& &1.id)
        |> Assignment.selected_labels_query()
        |> Repo.all()
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

      Enum.map(resources, &Map.put(&1, :labels, Map.get(labels, &1.id, [])))
    else
      resources
    end
  end

  defp preload_for_fields(resource, %{key: "document"} = descriptor, fields) do
    [resource] |> preload_for_fields(descriptor, fields) |> hd()
  end

  defp project_resource_fields(query, %{key: key}, fields) when key in ["document", "label"] do
    fields =
      if key == "label" and :resource_types in fields, do: [:resources | fields], else: fields

    fields = Enum.uniq([:id | fields -- [:resource_types, :labels]])
    select(query, [row], struct(row, ^fields))
  end

  defp serialize(resource, descriptor, fields) do
    Map.new(fields, &{&1, serialize_field(resource, descriptor, &1)})
  end

  defp serialize_field(resource, %{key: "label"}, :resource_types),
    do: resource.resources

  defp serialize_field(resource, _descriptor, field),
    do: normalize_value(Map.get(resource, field))
end

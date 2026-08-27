defmodule Zaq.Agent.Tools.Resources.Query do
  @moduledoc """
  Safe Ecto query builder for the `resources.query` tool.

  All dynamic behavior is driven by `Resources.Registry` descriptors. The LLM can
  choose resource keys and field names, but only allowlisted fields become Ecto
  query expressions or serialized output.
  """

  import Ecto.Query

  alias Zaq.Accounts.People
  alias Zaq.Accounts.PersonChannel
  alias Zaq.Channels.RetrievalChannel
  alias Zaq.Identity.ActorNormalizer
  alias Zaq.Permissions
  alias Zaq.Permissions.ResourcePermission
  alias Zaq.Repo

  @default_limit 20

  @type query_result ::
          {:ok, map()} | {:error, term()}

  @doc """
  Returns the descriptor's base Ecto query with the same private-resource
  authorization enforced by `resources.query`.
  """
  @spec authorized_query(map(), map()) :: {:ok, Ecto.Query.t()} | {:error, term()}
  def authorized_query(%{public?: true, module: module}, _context),
    do: {:ok, from(row in module)}

  def authorized_query(%{module: module} = descriptor, context) do
    if skip_permissions?(context) do
      {:ok, from(row in module)}
    else
      {:ok, private_authorized_query(descriptor, context)}
    end
  end

  defp private_authorized_query(%{module: module} = descriptor, context) do
    {person_id, team_ids} = authorization_subject(context)
    resource_type = resource_type(descriptor.module)
    subject_condition = permission_subject_condition(person_id, team_ids)

    permission_condition =
      dynamic(
        [perm],
        perm.resource_type == ^resource_type and
          fragment("? = ANY(?)", "read", perm.access_rights) and ^subject_condition
      )

    permissions =
      from perm in ResourcePermission,
        where: ^permission_condition

    authorized_resources =
      from perm in subquery(permissions),
        join: row in ^module,
        on: field(row, :id) == fragment("?::bigint", perm.resource_id),
        select: row,
        distinct: true

    from(row in subquery(authorized_resources))
  end

  defp permission_subject_condition(nil, team_ids), do: dynamic([perm], perm.team_id in ^team_ids)

  defp permission_subject_condition(person_id, team_ids),
    do: dynamic([perm], perm.person_id == ^person_id or perm.team_id in ^team_ids)

  @spec run(map(), map(), map()) :: query_result()
  def run(descriptor, params, context) do
    with :ok <- validate_requested_fields(descriptor, params),
         :ok <- validate_filter_fields(descriptor, params),
         :ok <- validate_sort_field(descriptor, params) do
      if present?(Map.get(params, :id)) do
        get_resource(descriptor, params, context)
      else
        list_resources(descriptor, params, context)
      end
    end
  end

  defp get_resource(descriptor, params, context) do
    id = Map.get(params, :id)

    case get_authorized_resource(descriptor, id, context) do
      {:error, reason} ->
        {:error, reason}

      nil ->
        if resource_exists?(descriptor, id) do
          {:error, :unauthorized}
        else
          {:ok, base_response(descriptor, params, %{resource: nil, found: false})}
        end

      resource ->
        fields = requested_fields(descriptor, params)
        resource = preload_for_fields(resource, descriptor, fields)
        resource_map = serialize(resource, descriptor, fields)

        {:ok,
         base_response(descriptor, params, %{
           resource: resource_map,
           found: true,
           count: 1,
           total_count: 1
         })}
    end
  end

  defp get_authorized_resource(%{public?: true, module: module}, id, _context),
    do: Repo.get(module, id)

  defp get_authorized_resource(%{module: _module} = descriptor, id, context) do
    with {:ok, query} <- authorized_query(descriptor, context) do
      query
      |> where([row], row.id == ^id)
      |> Repo.one()
    end
  end

  defp list_resources(descriptor, params, context) do
    with {:ok, query} <- authorized_query(descriptor, context) do
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

  defp resource_exists?(%{public?: true}, _id), do: false

  defp resource_exists?(%{module: module}, id) do
    Repo.exists?(from row in module, where: row.id == ^id)
  end

  defp apply_search(query, _descriptor, value) when value in [nil, ""], do: query

  defp apply_search(query, %{key: "channel_config"} = descriptor, value) when is_binary(value) do
    pattern = "%#{escape_like(String.trim(value))}%"

    descriptor.search_fields
    |> Enum.map(&channel_config_search_condition(&1, pattern, value))
    |> combine_conditions()
    |> then(fn condition -> from(row in query, where: ^condition) end)
  end

  defp apply_search(query, descriptor, value) when is_binary(value) do
    pattern = "%#{escape_like(String.trim(value))}%"

    descriptor.search_fields
    |> Enum.map(&search_condition(&1, pattern, value))
    |> combine_conditions()
    |> then(fn condition -> from(row in query, where: ^condition) end)
  end

  defp apply_search(query, _descriptor, _value), do: query

  defp search_condition(field, pattern, raw_value) when field in [:tags] do
    dynamic(
      [row],
      ilike(fragment("array_to_string(?, ' ')", field(row, ^field)), ^pattern) or
        fragment("? = ANY(?)", ^raw_value, field(row, ^field))
    )
  end

  defp search_condition(field, pattern, _raw_value)
       when field in [
              :id,
              :person_id,
              :channel_config_id,
              :retrieval_channel_id,
              :configured_agent_id
            ] do
    dynamic([row], ilike(fragment("?::text", field(row, ^field)), ^pattern))
  end

  defp search_condition(field, pattern, _raw_value) do
    dynamic([row], ilike(field(row, ^field), ^pattern))
  end

  defp channel_config_search_condition(:retrieval_channels, pattern, _raw_value) do
    dynamic(
      [row],
      fragment(
        "EXISTS (SELECT 1 FROM retrieval_channels rc WHERE rc.channel_config_id = ? AND (rc.channel_id ILIKE ? OR rc.channel_name ILIKE ? OR rc.team_id ILIKE ? OR rc.team_name ILIKE ?))",
        field(row, :id),
        ^pattern,
        ^pattern,
        ^pattern,
        ^pattern
      )
    )
  end

  defp channel_config_search_condition(field, pattern, raw_value),
    do: search_condition(field, pattern, raw_value)

  defp combine_conditions([condition | conditions]) do
    Enum.reduce(conditions, condition, fn condition, acc -> dynamic(^acc or ^condition) end)
  end

  defp apply_filters(query, descriptor, filters) when is_map(filters) do
    Enum.reduce(filters, query, fn {field_name, value}, acc ->
      field = field_atom!(descriptor.filter_fields, field_name)
      apply_filter(acc, field, value)
    end)
  end

  defp apply_filters(query, _descriptor, _filters), do: query

  defp apply_filter(query, field, value)
       when field in [
              :tags,
              :team_ids,
              :provided_tool_keys,
              :allowed_tools,
              :enabled_mcp_endpoint_ids
            ] do
    values = List.wrap(value)
    from(row in query, where: fragment("? && ?", field(row, ^field), ^values))
  end

  defp apply_filter(query, field, value) do
    from(row in query, where: field(row, ^field) == ^value)
  end

  defp apply_sort(query, descriptor, params) do
    field =
      field_atom!(descriptor.sort_fields, Map.get(params, :sort_by) || descriptor.default_sort)

    direction = if Map.get(params, :sort_dir) == "desc", do: :desc, else: :asc

    order_by(query, [row], [{^direction, field(row, ^field)}])
  end

  defp count(query) do
    query
    |> exclude(:order_by)
    |> Repo.aggregate(:count, :id)
  end

  defp validate_requested_fields(descriptor, params) do
    validate_field_names(descriptor.fields, Map.get(params, :fields, []), :unsupported_field)
  end

  defp validate_filter_fields(descriptor, params) do
    filters = Map.get(params, :filters, %{}) || %{}

    if is_map(filters) do
      validate_field_names(descriptor.filter_fields, Map.keys(filters), :unsupported_filter)
    else
      {:error, :invalid_filters}
    end
  end

  defp validate_sort_field(descriptor, params) do
    case Map.get(params, :sort_by) do
      nil -> :ok
      field -> validate_field_names(descriptor.sort_fields, [field], :unsupported_sort)
    end
  end

  defp validate_field_names(_allowed, [], _error), do: :ok

  defp validate_field_names(allowed, requested, error) when is_list(requested) do
    allowed_names = MapSet.new(Enum.map(allowed, &to_string/1))

    case Enum.reject(requested, &(to_string(&1) in allowed_names)) do
      [] -> :ok
      fields -> {:error, {error, Enum.map(fields, &to_string/1)}}
    end
  end

  defp validate_field_names(_allowed, _requested, error), do: {:error, error}

  defp requested_fields(descriptor, params) do
    case Map.get(params, :fields, []) do
      [] -> descriptor.fields
      fields -> Enum.map(fields, &field_atom!(descriptor.fields, &1))
    end
  end

  defp field_atom!(allowed, field) when is_atom(field) do
    if field in allowed, do: field, else: raise(ArgumentError, "unsupported field")
  end

  defp field_atom!(allowed, field) do
    Enum.find(allowed, &(to_string(&1) == to_string(field))) ||
      raise(ArgumentError, "unsupported field")
  end

  defp serialize(resource, descriptor, fields) do
    fields
    |> Enum.filter(&(&1 in descriptor.fields))
    |> Map.new(fn field -> {field, serialize_field(resource, descriptor, field)} end)
  end

  defp serialize_field(resource, %{key: "person"}, :channels) do
    resource
    |> Map.get(:channels, [])
    |> serialize_channels()
  end

  defp serialize_field(resource, %{key: "channel_config"}, :retrieval_channels) do
    resource
    |> Map.get(:retrieval_channels, [])
    |> serialize_retrieval_channels()
  end

  defp serialize_field(resource, _descriptor, field),
    do: normalize_value(Map.get(resource, field))

  defp serialize_channels(%Ecto.Association.NotLoaded{}), do: []

  defp serialize_channels(channels) when is_list(channels) do
    Enum.map(channels, fn channel ->
      %{
        id: channel.id,
        platform: channel.platform,
        channel_identifier: channel.channel_identifier,
        username: channel.username,
        display_name: channel.display_name,
        phone: channel.phone,
        last_interaction_at: normalize_value(channel.last_interaction_at),
        dm_channel_id: channel.dm_channel_id,
        weight: channel.weight,
        inserted_at: normalize_value(channel.inserted_at),
        updated_at: normalize_value(channel.updated_at)
      }
    end)
  end

  defp serialize_retrieval_channels(%Ecto.Association.NotLoaded{}), do: []

  defp serialize_retrieval_channels(channels) when is_list(channels) do
    Enum.map(channels, fn channel ->
      %{
        id: channel.id,
        channel_config_id: channel.channel_config_id,
        configured_agent_id: channel.configured_agent_id,
        channel_id: channel.channel_id,
        channel_name: channel.channel_name,
        team_id: channel.team_id,
        team_name: channel.team_name,
        active: channel.active,
        agent_routing_mode: channel.agent_routing_mode,
        inserted_at: normalize_value(channel.inserted_at),
        updated_at: normalize_value(channel.updated_at)
      }
    end)
  end

  defp preload_for_fields(resources, %{key: "person"}, fields) when is_list(resources) do
    if :channels in fields,
      do: Repo.preload(resources, channels: channels_query()),
      else: resources
  end

  defp preload_for_fields(resources, %{key: "channel_config"}, fields) when is_list(resources) do
    if :retrieval_channels in fields,
      do: Repo.preload(resources, retrieval_channels: retrieval_channels_query()),
      else: resources
  end

  defp preload_for_fields(resource, %{key: "person"}, fields) do
    if :channels in fields, do: Repo.preload(resource, channels: channels_query()), else: resource
  end

  defp preload_for_fields(resource, %{key: "channel_config"}, fields) do
    if :retrieval_channels in fields,
      do: Repo.preload(resource, retrieval_channels: retrieval_channels_query()),
      else: resource
  end

  defp preload_for_fields(resources_or_resource, _descriptor, _fields), do: resources_or_resource

  defp channels_query do
    from(channel in PersonChannel, order_by: channel.weight)
  end

  defp retrieval_channels_query do
    from(channel in RetrievalChannel, order_by: [asc: channel.channel_name, asc: channel.id])
  end

  defp normalize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_value(value), do: value

  defp base_response(descriptor, params, values) do
    %{
      resource_type: descriptor.key,
      mode: if(present?(Map.get(params, :id)), do: "get", else: "query"),
      resource: nil,
      resources: [],
      descriptions: [],
      found: false,
      count: 0,
      total_count: 0,
      limit: page_limit(params, descriptor),
      offset: page_offset(params)
    }
    |> Map.merge(values)
  end

  defp page_limit(params, descriptor) do
    params
    |> Map.get(:limit, @default_limit)
    |> clamp_integer(@default_limit, 1, descriptor.max_limit)
  end

  defp page_offset(params) do
    params
    |> Map.get(:offset, 0)
    |> clamp_integer(0, 0, 1_000_000)
  end

  defp clamp_integer(value, _default, min, max) when is_integer(value) do
    value |> max(min) |> min(max)
  end

  defp clamp_integer(value, default, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> clamp_integer(int, default, min, max)
      _ -> default
    end
  end

  defp clamp_integer(_value, default, _min, _max), do: default

  defp authorization_subject(context) do
    actor = Map.get(context, :actor) || Map.get(context, "actor")

    case ActorNormalizer.person_id(actor) ||
           ActorNormalizer.normalize_id(Map.get(context, :person_id)) do
      nil -> {nil, effective_team_ids(context, actor, nil)}
      person_id -> {person_id, effective_team_ids(context, actor, person_id)}
    end
  end

  defp effective_team_ids(context, actor, person_id) do
    actor_team_ids(actor, person_id)
    |> case do
      [] -> context_team_ids(context)
      ids -> ids
    end
    |> Permissions.with_everyone_team_ids()
  end

  defp actor_team_ids(actor, nil), do: ActorNormalizer.team_ids(actor)

  defp actor_team_ids(actor, person_id) do
    case ActorNormalizer.team_ids(actor) do
      [] -> person_id |> People.get_person() |> person_team_ids()
      ids -> ids
    end
  end

  defp context_team_ids(context) do
    case Map.get(context, :team_ids) || Map.get(context, "team_ids") do
      ids when is_list(ids) -> ids
      _ -> []
    end
  end

  defp person_team_ids(%{team_ids: ids}) when is_list(ids), do: ids
  defp person_team_ids(_), do: []

  defp skip_permissions?(context) do
    Map.get(context, :skip_permissions) == true or Map.get(context, "skip_permissions") == true
  end

  defp resource_type(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  defp present?(value), do: value not in [nil, ""]

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end

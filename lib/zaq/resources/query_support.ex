defmodule Zaq.Resources.QuerySupport do
  @moduledoc """
  Shared allowlist validation, read-grant queries and response conventions for
  resource queries. Owning roles supply server-owned descriptors and execute
  their own queries; this module has no domain-specific resource projections.
  """
  import Ecto.Query
  alias Zaq.Accounts.People
  alias Zaq.Identity.ActorNormalizer
  alias Zaq.Permissions
  alias Zaq.Permissions.ResourcePermission

  @default_limit 20

  @doc "Formats an authorized get result, including a missing or filtered-out result."
  @spec get_response(map(), map(), map() | nil) :: {:ok, map()}
  def get_response(descriptor, params, nil),
    do: {:ok, base_response(descriptor, params, %{resource: nil, found: false})}

  def get_response(descriptor, params, resource) do
    {:ok,
     base_response(descriptor, params, %{
       resource: resource,
       found: true,
       count: 1,
       total_count: 1
     })}
  end

  @doc "Builds the base read query from trusted identity and an allowlisted descriptor."
  @spec authorized_query(map(), map()) :: {:ok, Ecto.Query.t()}
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

  @doc "Rejects requested output fields outside the descriptor allowlist."
  @spec validate_requested_fields(map(), map()) :: :ok | {:error, term()}
  def validate_requested_fields(descriptor, params) do
    validate_field_names(descriptor.fields, Map.get(params, :fields, []), :unsupported_field)
  end

  @doc "Rejects filter names outside the descriptor allowlist."
  @spec validate_filter_fields(map(), map()) :: :ok | {:error, term()}
  def validate_filter_fields(descriptor, params) do
    filters = Map.get(params, :filters, %{}) || %{}

    if is_map(filters) do
      validate_field_names(descriptor.filter_fields, Map.keys(filters), :unsupported_filter)
    else
      {:error, :invalid_filters}
    end
  end

  @doc "Rejects sort fields outside the descriptor allowlist."
  @spec validate_sort_field(map(), map()) :: :ok | {:error, term()}
  def validate_sort_field(descriptor, params) do
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

  @doc "Resolves requested output fields, defaulting to the descriptor fields."
  @spec requested_fields(map(), map()) :: [atom()]
  def requested_fields(descriptor, params) do
    case Map.get(params, :fields, []) do
      [] -> descriptor.fields
      fields -> Enum.map(fields, &field_atom!(descriptor.fields, &1))
    end
  end

  @doc "Resolves an allowlisted field without creating atoms."
  @spec field_atom!([atom()], atom() | String.t()) :: atom()
  def field_atom!(allowed, field) when is_atom(field) do
    if field in allowed, do: field, else: raise(ArgumentError, "unsupported field")
  end

  def field_atom!(allowed, field) do
    Enum.find(allowed, &(to_string(&1) == to_string(field))) ||
      raise(ArgumentError, "unsupported field")
  end

  @doc "Serializes timestamps while preserving other resource values."
  @spec normalize_value(term()) :: term()
  def normalize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def normalize_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def normalize_value(value), do: value

  @doc "Builds the stable resources.query response envelope."
  @spec base_response(map(), map(), map()) :: map()
  def base_response(descriptor, params, values) do
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

  @doc "Clamps the requested page size to the descriptor limit."
  @spec page_limit(map(), map()) :: pos_integer()
  def page_limit(params, descriptor) do
    params
    |> Map.get(:limit, @default_limit)
    |> clamp_integer(@default_limit, 1, descriptor.max_limit)
  end

  @doc "Normalizes and bounds the requested result offset."
  @spec page_offset(map()) :: non_neg_integer()
  def page_offset(params) do
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

  @doc "Recognizes only an explicit trusted-context permission bypass."
  @spec skip_permissions?(map()) :: boolean()
  def skip_permissions?(context) do
    Map.get(context, :skip_permissions) == true or Map.get(context, "skip_permissions") == true
  end

  defp resource_type(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  @doc "Checks whether a get-by-ID argument was provided."
  @spec present?(term()) :: boolean()
  def present?(value), do: value not in [nil, ""]

  @doc "Escapes SQL LIKE wildcard characters for literal search."
  @spec escape_like(String.t()) :: String.t()
  def escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end

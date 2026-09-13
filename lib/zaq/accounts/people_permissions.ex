defmodule Zaq.Accounts.PeoplePermissions do
  @moduledoc """
  People capability grants and their explicit administration matrix.

  Resolve identity through `People.get_person/1` before calling predicates. Only
  loaded, persisted Person structs are accepted; their supplied current team IDs
  are used without identity queries or caching. Status is authentication eligibility,
  not grant semantics. Missing identity always denies, including global grants.
  """
  import Ecto.Query
  alias Zaq.Accounts.{People, PeoplePermissionGrant, Person}
  alias Zaq.Repo

  @type scope :: :all_people | {:team, pos_integer()}
  @type write_result :: {:ok, term()} | {:error, atom() | Ecto.Changeset.t()}

  @spec effective_permissions(term()) :: MapSet.t(atom())
  def effective_permissions(%Person{id: id, team_ids: teams, __meta__: %{state: :loaded}})
      when is_integer(id) and id > 0 and is_list(teams) do
    from(g in PeoplePermissionGrant,
      where: g.scope_type == "all_people" or (g.scope_type == "team" and g.scope_id in ^teams),
      select: g.permission
    )
    |> Repo.all()
    |> MapSet.new(fn stored ->
      {:ok, permission} = PeoplePermissionGrant.cast_permission(stored)
      permission
    end)
  end

  def effective_permissions(_), do: MapSet.new()

  @doc """
  Checks raw membership for one permission or ALL permissions in a nonempty list.

  Accepts known atoms and exact storage strings, with duplicates and order ignored.
  Empty lists and invalid inputs deny. Valid requirements resolve effective grants
  once; no implicit prerequisites are added. Each caller declares its requirements.
  """
  @spec allowed?(term(), term()) :: boolean()
  def allowed?(person, permission_or_permissions) do
    case cast_requirements(permission_or_permissions) do
      {:ok, required} -> MapSet.subset?(required, effective_permissions(person))
      {:error, _} -> false
    end
  end

  defp cast_requirements([_ | _] = permissions),
    do: cast_requirements(permissions, MapSet.new())

  defp cast_requirements(permission) do
    with {:ok, permission} <- PeoplePermissionGrant.cast_permission(permission) do
      {:ok, MapSet.new([permission])}
    end
  end

  defp cast_requirements([], required), do: {:ok, required}

  defp cast_requirements([permission | rest], required) do
    with {:ok, permission} <- PeoplePermissionGrant.cast_permission(permission) do
      cast_requirements(rest, MapSet.put(required, permission))
    end
  end

  defp cast_requirements(_, _), do: {:error, :invalid_permission}

  @spec list_grants() :: [PeoplePermissionGrant.t()]
  def list_grants, do: Repo.all(from g in PeoplePermissionGrant, order_by: g.id)

  @doc "Atomically inserts or returns the existing grant, preserving its ID and timestamps."
  @spec grant(scope(), term()) :: write_result()
  def grant(scope, permission) do
    with {:ok, attrs} <- grant_attrs(scope, permission) do
      # A no-op conflict update returns the actual winner atomically, even when a
      # concurrent revoke follows. DO NOTHING then SELECT has a deletion window.
      %PeoplePermissionGrant{}
      |> PeoplePermissionGrant.changeset(attrs)
      |> Repo.insert(
        on_conflict: [set: [permission: attrs.permission]],
        conflict_target: conflict_target(scope),
        returning: true
      )
    end
  end

  @doc "Deletes only the explicit scope grant; repeated revocations succeed."
  @spec revoke(scope(), term()) :: write_result()
  def revoke(scope, permission) do
    with {:ok, attrs} <- grant_attrs(scope, permission) do
      query =
        from g in PeoplePermissionGrant,
          where: g.scope_type == ^attrs.scope_type and g.permission == ^attrs.permission

      query =
        case scope do
          :all_people -> query
          {:team, id} -> from g in query, where: g.scope_id == ^id
        end

      {count, _} = Repo.delete_all(query)
      {:ok, count}
    end
  end

  @doc "Rows are ordered capabilities; columns are All People then teams by name. Cells are explicit, not inherited."
  @spec permissions_matrix() :: %{scopes: [map()], rows: [map()]}
  def permissions_matrix do
    scopes = [
      %{scope: :all_people, label: "All People"}
      | Enum.map(People.list_teams(), &%{scope: {:team, &1.id}, label: &1.name})
    ]

    grants = list_grants()

    rows =
      Enum.map(PeoplePermissionGrant.permissions(), fn metadata ->
        explicit =
          grants
          |> Enum.filter(&(&1.permission == Atom.to_string(metadata.permission)))
          |> MapSet.new(fn
            %{scope_type: "all_people"} -> :all_people
            %{scope_id: id} -> {:team, id}
          end)

        Map.put(metadata, :grants, explicit)
      end)

    %{scopes: scopes, rows: rows}
  end

  defp grant_attrs(scope, permission) do
    with {:ok, type, id} <- cast_scope(scope),
         {:ok, permission} <- PeoplePermissionGrant.cast_permission(permission) do
      {:ok, %{scope_type: type, scope_id: id, permission: Atom.to_string(permission)}}
    end
  end

  defp cast_scope(:all_people), do: {:ok, "all_people", nil}
  defp cast_scope({:team, id}) when is_integer(id) and id > 0, do: {:ok, "team", id}
  defp cast_scope(_), do: {:error, :invalid_scope}

  defp conflict_target(:all_people),
    do: {:unsafe_fragment, "(permission) WHERE scope_type = 'all_people'"}

  defp conflict_target({:team, _}),
    do: {:unsafe_fragment, "(scope_id, permission) WHERE scope_type = 'team'"}
end

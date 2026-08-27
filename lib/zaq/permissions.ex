defmodule Zaq.Permissions do
  @moduledoc """
  Resource-based access control context.

  Manages who can do what on a given resource (document, workflow, etc.).
  Permission checks are scoped to `resource_type` + `resource_id` pairs —
  the resource type is derived automatically from the struct module name.

  ## Security contract

  - `can?(nil, right, resource)` always returns `false`.
    A nil person_id is never an implicit permission grant.
  - Admin bypass requires explicit `skip_permissions: true` in opts.
    It is opt-in only and must never be triggered implicitly.

  ## Usage

      # Grant
      {:ok, _perm} = Permissions.grant(workflow, %{person_id: person.id, access_rights: ["run"]})

      # Check
      if Permissions.can?(person, :run, workflow) do
        Workflows.create_run(workflow, source_event, ctx)
      end

      # Revoke
      {:ok, _} = Permissions.revoke(workflow, perm)
  """

  import Ecto.Query

  alias Zaq.Accounts.{Person, Team}
  alias Zaq.Permissions.ResourcePermission
  alias Zaq.Repo

  @doc """
  Grants access rights to a person or team for the given resource.

  `attrs` must include either `person_id` or `team_id`, plus `access_rights`.
  Uses upsert semantics — if a permission row already exists for the same
  (resource_type, resource_id, person_id/team_id), the access_rights are updated.
  """
  @spec grant(struct(), map(), keyword()) ::
          {:ok, ResourcePermission.t()} | {:error, Ecto.Changeset.t()}
  def grant(resource, attrs, _opts \\ []) do
    {resource_type, resource_id} = resource_coords(resource)
    now = DateTime.utc_now(:second)

    attrs = Map.merge(attrs, %{resource_type: resource_type, resource_id: resource_id})

    conflict_fragment =
      if Map.has_key?(attrs, :person_id) do
        "(resource_type, resource_id, person_id) WHERE person_id IS NOT NULL"
      else
        "(resource_type, resource_id, team_id) WHERE team_id IS NOT NULL"
      end

    access_rights = Map.get(attrs, :access_rights, ["read"])

    Repo.insert(
      ResourcePermission.changeset(%ResourcePermission{}, attrs),
      on_conflict: [set: [access_rights: access_rights, updated_at: now]],
      conflict_target: {:unsafe_fragment, conflict_fragment}
    )
  end

  @doc """
  Revokes the given permission row.
  Returns `:ok` on success, `{:error, changeset}` on DB constraint failure.
  """
  @spec revoke(struct(), ResourcePermission.t(), keyword()) ::
          :ok | {:error, Ecto.Changeset.t()}
  def revoke(_resource, %ResourcePermission{} = permission, opts \\ []) do
    revoker = Keyword.get(opts, :revoker, Zaq.Permissions.PermissionRevoker)

    case revoker.delete(permission) do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Returns `true` if `person` has `right` on `resource`.

  Checks both direct person grants and grants via any of the person's teams.
  A `nil` person always returns `false` — it is never an implicit grant.

  Pass `skip_permissions: true` in opts for explicit admin bypass.
  """
  @spec can?(Person.t() | nil, atom(), struct(), keyword()) :: boolean()
  def can?(person, right, resource, opts \\ [])

  def can?(nil, right, resource, opts) do
    Keyword.get(opts, :skip_permissions, false) or
      permission_exists?(nil, right, resource, opts)
  end

  def can?(%Person{} = person, right, resource, opts) do
    if Keyword.get(opts, :skip_permissions, false) do
      true
    else
      permission_exists?(person, right, resource, opts)
    end
  end

  @doc "Returns true when the resource is granted to the system Everyone team."
  @spec public?(struct(), keyword()) :: boolean()
  def public?(resource, opts \\ []) do
    resource
    |> resources_with_ancestors(Keyword.get(opts, :ancestors, []))
    |> Enum.any?(fn res ->
      {resource_type, resource_id} = resource_coords(res)

      Repo.exists?(
        from p in ResourcePermission,
          where:
            p.resource_type == ^resource_type and
              p.resource_id == ^resource_id and
              p.team_id == ^everyone_team_id() and
              fragment("? = ANY(?)", "read", p.access_rights)
      )
    end)
  end

  @doc "Grants public read access through the system Everyone team."
  @spec grant_public(struct(), keyword()) ::
          {:ok, ResourcePermission.t()} | {:error, Ecto.Changeset.t()}
  def grant_public(resource, opts \\ []),
    do: grant(resource, %{team_id: everyone_team_id(), access_rights: ["read"]}, opts)

  @doc "Revokes direct public access from a resource."
  @spec revoke_public(struct(), keyword()) :: :ok | {:error, term()}
  def revoke_public(resource, opts \\ []) do
    case direct_public_permission(resource) do
      nil -> :ok
      permission -> revoke(resource, permission, opts)
    end
  end

  @doc "Lists permissions directly attached to a resource."
  @spec list_direct(struct(), keyword()) :: [ResourcePermission.t()]
  def list_direct(resource, opts \\ []), do: list(resource, opts)

  @doc "Lists direct and inherited grants for a resource and its supplied ancestors."
  @spec list_effective(struct(), keyword()) :: [map()]
  def list_effective(resource, opts \\ []) do
    resource
    |> resources_with_ancestors(Keyword.get(opts, :ancestors, []))
    |> Enum.with_index()
    |> Enum.flat_map(fn {res, index} ->
      Enum.map(list(res), fn permission ->
        %{permission: permission, origin: res, inherited?: index > 0}
      end)
    end)
  end

  @doc "Replaces all direct grants on a resource with the desired grant maps."
  @spec replace(struct(), [map()], keyword()) ::
          {:ok, [ResourcePermission.t()]} | {:error, term()}
  def replace(resource, desired_grants, opts \\ []) when is_list(desired_grants) do
    Repo.transaction(fn ->
      revoke_existing(resource, opts)
      grant_desired(resource, desired_grants)
    end)
  end

  defp revoke_existing(resource, opts) do
    Enum.each(list(resource), fn permission ->
      case revoke(resource, permission, opts) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp grant_desired(resource, desired_grants) do
    Enum.map(desired_grants, fn attrs ->
      case grant(resource, attrs) do
        {:ok, permission} -> permission
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Lists all permission rows for the given resource.
  """
  @spec list(struct(), keyword()) :: [ResourcePermission.t()]
  def list(resource, _opts \\ []) do
    {resource_type, resource_id} = resource_coords(resource)

    ResourcePermission
    |> where([p], p.resource_type == ^resource_type and p.resource_id == ^resource_id)
    |> preload([:person, :team])
    |> Repo.all()
  end

  @doc false
  def everyone_team_id do
    Repo.one!(from t in Team, where: t.system_key == "everyone", select: t.id)
  end

  def with_everyone_team_ids(team_ids) when is_list(team_ids),
    do: [everyone_team_id() | team_ids] |> Enum.reject(&is_nil/1) |> Enum.uniq()

  defp permission_exists?(person, right, resource, opts) do
    right_str = to_string(right)
    team_ids = effective_team_ids(person)

    resource
    |> resources_with_ancestors(Keyword.get(opts, :ancestors, []))
    |> Enum.any?(fn res ->
      {resource_type, resource_id} = resource_coords(res)

      principal_condition = principal_condition(person, team_ids)

      Repo.exists?(
        from p in ResourcePermission,
          where:
            p.resource_type == ^resource_type and
              p.resource_id == ^resource_id and
              fragment("? = ANY(?)", ^right_str, p.access_rights),
          where: ^principal_condition
      )
    end)
  end

  defp principal_condition(nil, team_ids), do: dynamic([p], p.team_id in ^team_ids)

  defp principal_condition(%Person{id: id}, team_ids),
    do: dynamic([p], p.person_id == ^id or p.team_id in ^team_ids)

  defp direct_public_permission(resource) do
    {resource_type, resource_id} = resource_coords(resource)

    Repo.one(
      from p in ResourcePermission,
        where:
          p.resource_type == ^resource_type and
            p.resource_id == ^resource_id and
            p.team_id == ^everyone_team_id(),
        preload: [:person, :team],
        limit: 1
    )
  end

  defp resources_with_ancestors(resource, ancestors), do: [resource | List.wrap(ancestors)]

  # Derives (resource_type, resource_id) from a struct.
  # resource_id is always a string to support both integer and UUID PKs.
  defp resource_coords(%{__struct__: module, id: id}) do
    resource_type =
      module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()

    {resource_type, to_string(id)}
  end

  defp effective_team_ids(nil), do: with_everyone_team_ids([])
  defp effective_team_ids(%Person{team_ids: team_ids}), do: with_everyone_team_ids(team_ids || [])
end

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
      :ok = Permissions.revoke(workflow, perm)
  """

  import Ecto.Query

  alias Zaq.Accounts.Person
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
  Returns `:ok` on success, `{:error, :not_found}` if the row no longer exists.
  """
  @spec revoke(struct(), ResourcePermission.t(), keyword()) :: :ok | {:error, :not_found}
  def revoke(_resource, %ResourcePermission{} = permission, _opts \\ []) do
    case Repo.delete(permission) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :not_found}
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

  def can?(nil, _right, _resource, opts) do
    Keyword.get(opts, :skip_permissions, false)
  end

  def can?(%Person{} = person, right, resource, opts) do
    if Keyword.get(opts, :skip_permissions, false) do
      true
    else
      {resource_type, resource_id} = resource_coords(resource)
      right_str = to_string(right)
      team_ids = person_team_ids(person)

      Repo.exists?(
        from p in ResourcePermission,
          where:
            p.resource_type == ^resource_type and
              p.resource_id == ^resource_id and
              fragment("? = ANY(?)", ^right_str, p.access_rights) and
              (p.person_id == ^person.id or p.team_id in ^team_ids)
      )
    end
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

  defp person_team_ids(%Person{team_ids: team_ids}), do: team_ids || []
end

defmodule Zaq.Permissions.ResourcePermission do
  @moduledoc """
  Ecto schema for polymorphic resource-level access permissions.

  Grants a person or team specific access rights to any resource type
  (e.g. "document", "workflow"). Either `person_id` or `team_id` must
  be set — enforced by a DB CHECK constraint and changeset validation.

  Uniqueness is enforced by partial indexes:
    - (resource_type, resource_id, person_id) WHERE person_id IS NOT NULL
    - (resource_type, resource_id, team_id)   WHERE team_id IS NOT NULL

  ## Resource preloading

  This schema does not carry a virtual resource field. To attach the real
  resource struct to a list of permissions, resolve it externally after
  fetching. Example for workflows:

      perms = Permissions.list(workflow)
      workflow_ids = Enum.map(perms, & &1.resource_id)
      workflows = Repo.all(from w in Workflow, where: w.id in ^workflow_ids)
      by_id = Map.new(workflows, &{to_string(&1.id), &1})
      Enum.map(perms, &Map.put(&1, :resource, by_id[&1.resource_id]))

  Resource-specific schemas (e.g. `Zaq.Permissions.DocumentPermission`) may add a
  virtual field for convenience when the resource type is always known.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Accounts.{Person, Team}

  @valid_rights ~w(read write update delete run view edit manage)

  @doc false
  def valid_rights, do: @valid_rights

  @type t :: %__MODULE__{}

  schema "resource_permissions" do
    field :resource_type, :string
    field :resource_id, :string
    belongs_to :person, Person
    belongs_to :team, Team
    field :access_rights, {:array, :string}, default: ["read"]

    timestamps(type: :utc_datetime)
  end

  def changeset(permission, attrs) do
    permission
    |> cast(attrs, [:resource_type, :resource_id, :person_id, :team_id, :access_rights])
    |> validate_required([:resource_type, :resource_id, :access_rights])
    |> validate_target_present()
    |> validate_subset(:access_rights, @valid_rights)
    |> foreign_key_constraint(:person_id)
    |> foreign_key_constraint(:team_id)
    |> unique_constraint([:resource_type, :resource_id, :person_id],
      name: :uix_resource_perm_person
    )
    |> unique_constraint([:resource_type, :resource_id, :team_id],
      name: :uix_resource_perm_team
    )
  end

  defp validate_target_present(changeset) do
    person_id = get_field(changeset, :person_id)
    team_id = get_field(changeset, :team_id)

    if is_nil(person_id) and is_nil(team_id) do
      add_error(changeset, :person_id, "either person_id or team_id must be present")
    else
      changeset
    end
  end
end

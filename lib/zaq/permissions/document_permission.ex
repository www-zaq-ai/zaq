defmodule Zaq.Permissions.DocumentPermission do
  @moduledoc """
  Document-scoped view of the `resource_permissions` table.

  A specialisation of `Zaq.Permissions.ResourcePermission` for the `"document"`
  resource type. Compared to the generic schema it:

  - Auto-sets `resource_type` to `"document"` on every changeset.
  - Restricts `access_rights` to CRUD operations only (`read`, `write`, `update`, `delete`).
  - Carries a virtual `:document` field populated by `list_person_permissions/1` for BO display.
  - Provides `build_permission_query/3` and `build_perm_join_condition/2` — Ecto query
    helpers used by `Zaq.Ingestion.DocumentAccess` to filter documents by caller identity.

  For generic, cross-resource permission management (grant, revoke, can?) use
  `Zaq.Permissions` and `Zaq.Permissions.ResourcePermission` instead.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Zaq.Accounts.{Person, Team}
  alias Zaq.Permissions.ResourcePermission

  @resource_type "document"
  # Documents support only CRUD rights. Workflow and other resource types
  # may support additional rights (run, view, edit, manage) via ResourcePermission.
  @valid_rights ~w(read write update delete)

  @after_compile __MODULE__
  @doc false
  def __after_compile__(_env, _bytecode) do
    all = ResourcePermission.valid_rights()
    diff = @valid_rights -- all

    unless diff == [] do
      raise "DocumentPermission @valid_rights contains rights not in ResourcePermission: #{inspect(diff)}"
    end
  end

  schema "resource_permissions" do
    field :resource_type, :string, default: @resource_type
    field :resource_id, :string
    belongs_to :person, Person
    belongs_to :team, Team
    field :access_rights, {:array, :string}, default: ["read"]
    # Virtual: populated by list_person_permissions/1 for BO display
    field :document, :any, virtual: true

    timestamps(type: :utc_datetime)
  end

  def changeset(permission, attrs) do
    permission
    |> cast(attrs, [:resource_id, :person_id, :team_id, :access_rights])
    |> put_change(:resource_type, @resource_type)
    |> validate_required([:resource_id, :access_rights])
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

  @doc """
  Builds a query returning integer `document_id` values from `resource_permissions`
  that match `person_id` or any of `team_ids` for the given `doc_ids`.

  Used by `DocumentAccess` to filter a known set of IDs (e.g. from vector search).
  """
  @spec build_permission_query(term(), [term()], [term()]) :: Ecto.Query.t()
  def build_permission_query(nil, team_ids, _doc_ids) when team_ids == [] do
    from(p in __MODULE__, where: false, select: p.resource_id)
  end

  def build_permission_query(nil, team_ids, doc_ids) do
    id_strings = Enum.map(doc_ids, &to_string/1)

    from(p in __MODULE__,
      where:
        p.resource_type == @resource_type and
          p.resource_id in ^id_strings and
          p.team_id in ^team_ids,
      select: fragment("?::integer", p.resource_id),
      distinct: true
    )
  end

  def build_permission_query(person_id, team_ids, doc_ids) do
    id_strings = Enum.map(doc_ids, &to_string/1)

    from(p in __MODULE__,
      where:
        p.resource_type == @resource_type and
          p.resource_id in ^id_strings and
          (p.person_id == ^person_id or p.team_id in ^team_ids),
      select: fragment("?::integer", p.resource_id),
      distinct: true
    )
  end

  @doc """
  Builds a named-binding dynamic WHERE condition on a `:perm` join for
  `person_id` / `team_ids` permission matching.

  Requires the query to have a `DocumentPermission` binding named `:perm`, joined with:
    `on: p.resource_type == "document" and p.resource_id == fragment("?::text", d.id)`
  """
  @spec build_perm_join_condition(term(), [term()]) :: Ecto.Query.dynamic_expr()
  def build_perm_join_condition(nil, []), do: dynamic([perm: p], false)

  def build_perm_join_condition(nil, team_ids),
    do: dynamic([perm: p], p.team_id in ^team_ids)

  def build_perm_join_condition(person_id, []),
    do: dynamic([perm: p], p.person_id == ^person_id)

  def build_perm_join_condition(person_id, team_ids),
    do: dynamic([perm: p], p.person_id == ^person_id or p.team_id in ^team_ids)

  # Intentionally mirrors the DB CHECK constraint — changeset validation gives
  # early feedback before hitting the database; the constraint ensures integrity
  # even for bulk inserts that bypass changesets.
  defp validate_target_present(changeset) do
    if is_nil(get_field(changeset, :person_id)) and is_nil(get_field(changeset, :team_id)) do
      add_error(changeset, :base, "must set person_id or team_id")
    else
      changeset
    end
  end
end

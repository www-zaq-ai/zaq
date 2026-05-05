defmodule Zaq.Ingestion.Permission do
  @moduledoc """
  Ecto schema for person- and team-level document access permissions.

  Each row grants a specific person or team access to a document with a set of
  access rights. Either `person_id` or `team_id` must be set (enforced by DB CHECK
  constraint). Uniqueness is enforced by partial indexes:
    - (document_id, person_id) WHERE person_id IS NOT NULL
    - (document_id, team_id)   WHERE team_id IS NOT NULL
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Zaq.Accounts.{Person, Team}
  alias Zaq.Ingestion.Document

  schema "document_permissions" do
    belongs_to :document, Document
    belongs_to :person, Person
    belongs_to :team, Team
    field :access_rights, {:array, :string}, default: ["read"]

    timestamps(type: :utc_datetime)
  end

  @valid_rights ~w(read write update delete)

  def changeset(permission, attrs) do
    permission
    |> cast(attrs, [:document_id, :person_id, :team_id, :access_rights])
    |> validate_required([:document_id, :access_rights])
    |> validate_target_present()
    |> validate_subset(:access_rights, @valid_rights)
    |> foreign_key_constraint(:document_id)
    |> foreign_key_constraint(:person_id)
    |> foreign_key_constraint(:team_id)
    |> unique_constraint([:document_id, :person_id], name: :uix_doc_perm_person)
    |> unique_constraint([:document_id, :team_id], name: :uix_doc_perm_team)
  end

  @doc """
  Builds a query returning `document_id` values from `document_permissions`
  that match `person_id` or any of `team_ids` for the given `doc_ids`.

  Used by `DocumentAccess` to filter a known set of IDs (e.g. from vector search).
  """
  @spec build_permission_query(term(), [term()], [term()]) :: Ecto.Query.t()
  def build_permission_query(nil, team_ids, _doc_ids) when team_ids == [] do
    from(p in __MODULE__, where: false, select: p.document_id)
  end

  def build_permission_query(nil, team_ids, doc_ids) do
    from(p in __MODULE__,
      where: p.document_id in ^doc_ids and p.team_id in ^team_ids,
      select: p.document_id,
      distinct: true
    )
  end

  def build_permission_query(person_id, team_ids, doc_ids) do
    from(p in __MODULE__,
      where:
        p.document_id in ^doc_ids and
          (p.person_id == ^person_id or p.team_id in ^team_ids),
      select: p.document_id,
      distinct: true
    )
  end

  @doc """
  Builds a named-binding dynamic WHERE condition on a `:perm` join for
  `person_id` / `team_ids` permission matching.

  Requires the query to have a `Permission` binding named `:perm`.
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

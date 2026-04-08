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

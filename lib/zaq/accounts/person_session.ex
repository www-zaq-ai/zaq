defmodule Zaq.Accounts.PersonSession do
  @moduledoc """
  Digest-only People authentication session, independent of BO sessions and
  conversation identifiers. Raw bearer tokens never enter this schema.
  Changesets accept trusted lifecycle attributes from PeopleAuth only.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @type t :: %__MODULE__{}
  schema "person_sessions" do
    belongs_to :person, Zaq.Accounts.Person
    field :token_digest, :binary, redact: true
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :last_seen_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  @doc "Validates trusted session lifecycle changes."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) do
    session
    |> change(attrs)
    |> validate_required([:person_id, :token_digest, :expires_at])
    |> validate_change(:token_digest, fn :token_digest, value ->
      if is_binary(value) and byte_size(value) == 32,
        do: [],
        else: [token_digest: "must be a 32-byte digest"]
    end)
    |> foreign_key_constraint(:person_id)
    |> unique_constraint(:token_digest)
    |> check_constraint(:token_digest, name: :person_sessions_digest_check)
    |> check_constraint(:expires_at, name: :person_sessions_expiry_check)
  end
end

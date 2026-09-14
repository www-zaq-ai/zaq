defmodule Zaq.Accounts.PersonLoginChallenge do
  @moduledoc """
  Digest-only, single-use People login challenge. The UUID is an opaque browser
  reference; the owning Person is never part of the public challenge descriptor.
  Changesets accept trusted lifecycle attributes from PeopleAuth, not request maps.
  Unfinished includes expired rows: issuance invalidates them before replacement.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @type t :: %__MODULE__{}
  schema "person_login_challenges" do
    belongs_to :person, Zaq.Accounts.Person
    field :token_digest, :binary, redact: true
    field :expires_at, :utc_datetime
    field :attempt_count, :integer, default: 0
    field :consumed_at, :utc_datetime
    field :invalidated_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  @doc "Validates trusted challenge lifecycle changes; database constraints remain authoritative."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(challenge, attrs) do
    challenge
    |> change(attrs)
    |> validate_required([:person_id, :token_digest, :expires_at, :attempt_count])
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_change(:token_digest, fn :token_digest, value ->
      if is_binary(value) and byte_size(value) == 32,
        do: [],
        else: [token_digest: "must be a 32-byte digest"]
    end)
    |> foreign_key_constraint(:person_id)
    |> unique_constraint(:person_id, name: :person_login_challenges_active_person_index)
    |> check_constraint(:attempt_count, name: :person_login_challenges_attempt_count_check)
    |> check_constraint(:consumed_at, name: :person_login_challenges_lifecycle_check)
    |> check_constraint(:token_digest, name: :person_login_challenges_digest_check)
    |> check_constraint(:expires_at, name: :person_login_challenges_expiry_check)
  end
end

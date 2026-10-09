defmodule Zaq.Accounts.PersonIdentity do
  @moduledoc "A native identity's unique Person owner within its provider authority."
  use Ecto.Schema
  import Ecto.Changeset
  @type t :: %__MODULE__{}

  schema "person_identities" do
    field :platform, :string
    field :authority, :string
    field :identifier, :string
    belongs_to :person, Zaq.Accounts.Person
    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:platform, :authority, :identifier, :person_id])
    |> validate_required([:platform, :authority, :identifier, :person_id])
    |> foreign_key_constraint(:person_id)
    |> unique_constraint([:platform, :authority, :identifier],
      error_key: :channel_identifier,
      message: "This channel identifier is already assigned."
    )
  end
end

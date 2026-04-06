defmodule Zaq.Accounts.Person do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_statuses ~w(active inactive)

  schema "people" do
    field :full_name, :string
    field :email, :string
    field :role, :string
    field :status, :string, default: "active"
    field :metadata, :map, default: %{}
    field :team_ids, {:array, :integer}, default: []

    has_many :channels, Zaq.Accounts.PersonChannel

    timestamps(type: :utc_datetime)
  end

  def changeset(person, attrs) do
    person
    |> cast(attrs, [:full_name, :email, :role, :status, :metadata, :team_ids])
    |> validate_required([:full_name])
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:email)
  end

  def update_changeset(person, attrs) do
    person
    |> cast(attrs, [:full_name, :email, :role, :status, :metadata, :team_ids])
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:email)
  end
end

defmodule Zaq.Accounts.Person do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_statuses ~w(active inactive)

  @type t :: %__MODULE__{}

  schema "people" do
    field :full_name, :string
    field :email, :string
    field :phone, :string
    field :role, :string
    field :status, :string, default: "active"
    field :incomplete, :boolean, default: true
    field :metadata, :map, default: %{}
    field :team_ids, {:array, :integer}, default: []

    has_many :channels, Zaq.Accounts.PersonChannel

    timestamps(type: :utc_datetime)
  end

  def changeset(person, attrs) do
    person
    |> cast(attrs, [:full_name, :email, :phone, :role, :status, :metadata, :team_ids])
    |> validate_required([:full_name])
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:email)
    |> put_incomplete_flag()
  end

  def update_changeset(person, attrs) do
    person
    |> cast(attrs, [:full_name, :email, :phone, :role, :status, :metadata, :team_ids])
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:email)
    |> put_incomplete_flag()
  end

  # Sets incomplete: false only when full_name, email, and phone are all present.
  defp put_incomplete_flag(changeset) do
    full_name = get_field(changeset, :full_name)
    email = get_field(changeset, :email)
    phone = get_field(changeset, :phone)

    complete? =
      is_binary(full_name) and full_name != "" and
        is_binary(email) and email != "" and
        is_binary(phone) and phone != ""

    put_change(changeset, :incomplete, not complete?)
  end
end

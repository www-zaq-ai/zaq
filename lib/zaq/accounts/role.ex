defmodule Zaq.Accounts.Role do
  @moduledoc """
  Ecto schema for user roles. Each role has a unique name and an optional metadata
  map for storing permissions or other attributes. Roles can have many users.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "roles" do
    field :name, :string
    field :meta, :map, default: %{}

    has_many :users, Zaq.Accounts.User

    timestamps()
  end

  def changeset(role, attrs) do
    role
    |> cast(attrs, [:name, :meta])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end

defmodule Zaq.Accounts.Team do
  @moduledoc """
  Represents a team or group label for organizing people.

  Teams have a many-to-many relationship with `Person` via the `team_ids`
  integer array column on the `people` table. This design avoids a join
  table at the cost of no database-level foreign key constraints on team
  membership.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "teams" do
    field :name, :string
    field :description, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(team, attrs) do
    team
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end

  def update_changeset(team, attrs) do
    team
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end

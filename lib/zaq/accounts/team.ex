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
    field :system_key, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(team, attrs) do
    team
    |> cast(attrs, [:name, :description, :system_key])
    |> validate_required([:name])
    |> unique_constraint(:name)
    |> unique_constraint(:system_key)
  end

  def update_changeset(team, attrs) do
    team
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> unique_constraint(:name)
    |> reject_system_team_update()
  end

  def system?(%__MODULE__{system_key: key}) when is_binary(key) and key != "", do: true
  def system?(_team), do: false

  defp reject_system_team_update(%{data: %__MODULE__{} = team} = changeset) do
    if system?(team),
      do: add_error(changeset, :base, "system teams cannot be changed"),
      else: changeset
  end
end

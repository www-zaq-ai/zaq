defmodule Zaq.Accounts.TeamTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.Team

  describe "system?/1" do
    test "returns true for a team with a non-empty system key" do
      team = %Team{name: "Everyone", system_key: "everyone"}

      assert Team.system?(team)
      refute Team.system?(%Team{system_key: nil})
      refute Team.system?(%Team{system_key: ""})
    end
  end

  describe "update_changeset/2" do
    test "adds a base error when updating a system team" do
      team = %Team{
        name: "Everyone",
        description: "Public access",
        system_key: "everyone"
      }

      changeset = Team.update_changeset(team, %{name: "Renamed", description: "Changed"})

      refute changeset.valid?
      assert errors_on(changeset) == %{base: ["system teams cannot be changed"]}
      assert Ecto.Changeset.get_change(changeset, :name) == "Renamed"
      assert Ecto.Changeset.get_change(changeset, :description) == "Changed"
    end
  end
end

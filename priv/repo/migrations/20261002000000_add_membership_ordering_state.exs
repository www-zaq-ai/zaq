defmodule Zaq.Repo.Migrations.AddMembershipOrderingState do
  use Ecto.Migration

  def change do
    alter table(:transcripts) do
      add :membership_state, :map, null: false, default: %{}
    end
  end
end

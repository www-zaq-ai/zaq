defmodule Zaq.Repo.Migrations.AddMessageHistoryContext do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :history_context, :map, null: false, default: %{}
    end
  end
end

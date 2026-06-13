defmodule Zaq.Repo.Migrations.AddTraceToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :trace, :map, null: false, default: []
    end
  end
end

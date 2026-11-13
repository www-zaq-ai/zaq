defmodule Zaq.Repo.Migrations.AddMessageRevisionTimes do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :edited_at, :utc_datetime_usec
      add :deleted_at, :utc_datetime_usec
    end
  end
end

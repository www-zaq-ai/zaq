defmodule Zaq.Repo.Migrations.AddCronFieldsToTriggers do
  use Ecto.Migration

  def change do
    alter table(:triggers) do
      add :trigger_type, :string, null: false, default: "event"
      add :cron_schedule, :string, null: true
    end
  end
end

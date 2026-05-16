defmodule Zaq.Repo.Migrations.SimplifyTriggers do
  use Ecto.Migration

  def change do
    drop table(:trigger_chains)

    alter table(:triggers) do
      add :event_name, :string, null: false, default: ""
      remove :type
      remove :config
      remove :execution_mode
      remove :max_concurrency
      remove :on_failure
    end

    create index(:triggers, [:event_name])
  end
end

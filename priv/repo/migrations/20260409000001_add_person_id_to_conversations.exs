defmodule Zaq.Repo.Migrations.AddPersonIdToConversations do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :person_id, references(:people, on_delete: :nilify_all)
    end

    create index(:conversations, [:person_id])
  end
end

defmodule Zaq.Repo.Migrations.CreatePersonIdentities do
  use Ecto.Migration

  def change do
    create table(:person_identities) do
      add :platform, :string, null: false
      add :authority, :text, null: false
      add :identifier, :text, null: false
      add :person_id, references(:people, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:person_identities, [:platform, :authority, :identifier])
    create index(:person_identities, [:person_id])

    alter table(:channels) do
      add :person_identity_id, references(:person_identities, on_delete: :nilify_all)
    end

    create index(:channels, [:person_identity_id])
  end
end

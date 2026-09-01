defmodule Zaq.Repo.Migrations.CreateHttpCredentialProviders do
  use Ecto.Migration

  def change do
    create table(:http_credential_providers) do
      add :name, :string, null: false
      add :auth_kind, :string, null: false
      add :placement, :string, null: false
      add :parameter_name, :string
      add :host_patterns, {:array, :string}, null: false, default: []
      add :enabled, :boolean, null: false, default: true
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:http_credential_providers, [:name])
    create index(:http_credential_providers, [:enabled])
  end
end

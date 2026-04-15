defmodule Zaq.Repo.Migrations.CreateAiProviderCredentials do
  use Ecto.Migration

  def change do
    create table(:ai_provider_credentials) do
      add :name, :string, null: false
      add :provider, :string, null: false
      add :endpoint, :string, null: false
      add :api_key, :text
      add :sovereign, :boolean, null: false, default: false
      add :description, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:ai_provider_credentials, [:name])
    create index(:ai_provider_credentials, [:provider])
  end
end

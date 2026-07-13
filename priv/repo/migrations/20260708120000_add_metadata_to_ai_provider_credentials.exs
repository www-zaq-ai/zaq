defmodule Zaq.Repo.Migrations.AddMetadataToAiProviderCredentials do
  use Ecto.Migration

  def change do
    alter table(:ai_provider_credentials) do
      add :metadata, :map, null: false, default: %{}
    end
  end
end

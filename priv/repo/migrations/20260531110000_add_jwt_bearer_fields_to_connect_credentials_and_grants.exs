defmodule Zaq.Repo.Migrations.AddJwtBearerFieldsToConnectCredentialsAndGrants do
  use Ecto.Migration

  def change do
    alter table(:connect_credentials) do
      add :issuer, :string
      add :private_key, :text
      add :key_id, :string
    end

    alter table(:connect_grants) do
      add :issuer, :string
      add :private_key, :text
      add :key_id, :string
      add :subject, :string
    end
  end
end

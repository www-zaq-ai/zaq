defmodule Zaq.Repo.Migrations.CreateConnectCredentialsAndGrants do
  use Ecto.Migration

  def change do
    create table(:connect_credentials) do
      add :name, :string, null: false
      add :provider, :string, null: false
      add :auth_kind, :string, null: false
      add :user_level, :boolean, null: false, default: false
      add :request_format, :string, null: false, default: "bearer"
      add :metadata, :map, null: false, default: %{}

      add :client_id, :string
      add :client_secret, :text
      add :scopes, {:array, :string}, null: false, default: []

      add :api_key, :text
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:connect_credentials, [:name])
    create index(:connect_credentials, [:provider])
    create index(:connect_credentials, [:auth_kind])

    create table(:connect_grants) do
      add :credential_id, references(:connect_credentials, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :auth_kind, :string, null: false
      add :resource_type, :string, null: false
      add :resource_id, :string, null: false
      add :owner_type, :string, null: false
      add :owner_id, :integer
      add :request_format, :string, null: false, default: "bearer"
      add :metadata, :map, null: false, default: %{}
      add :expires_at, :utc_datetime
      add :status, :string, null: false, default: "active"

      add :access_token, :text
      add :refresh_token, :text
      add :scopes, {:array, :string}, null: false, default: []

      add :api_key, :text

      timestamps(type: :utc_datetime)
    end

    create index(:connect_grants, [:credential_id])
    create index(:connect_grants, [:provider])
    create index(:connect_grants, [:status])
    create index(:connect_grants, [:expires_at])

    create index(:connect_grants, [
             :resource_type,
             :resource_id,
             :owner_type,
             :owner_id,
             :provider,
             :status
           ])
  end
end

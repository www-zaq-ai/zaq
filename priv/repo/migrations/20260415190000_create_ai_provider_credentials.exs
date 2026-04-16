defmodule Zaq.Repo.Migrations.CreateAIProviderCredentials do
  use Ecto.Migration

  def up do
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

    flush()

    backfill_credential!("llm", "LLM", "http://localhost:11434/v1")
    backfill_credential!("embedding", "Embedding", "http://localhost:11434/v1")
    backfill_credential!("image_to_text", "Image to Text", "http://localhost:11434/v1")
  end

  def down do
    execute("""
    DELETE FROM system_configs
    WHERE key IN ('llm.credential_id', 'embedding.credential_id', 'image_to_text.credential_id')
    """)

    drop index(:ai_provider_credentials, [:provider])
    drop unique_index(:ai_provider_credentials, [:name])
    drop table(:ai_provider_credentials)
  end

  defp backfill_credential!(prefix, label, default_endpoint) do
    query = """
    WITH provider_row AS (
      SELECT value AS provider
      FROM system_configs
      WHERE key = $1
        AND NULLIF(BTRIM(value), '') IS NOT NULL
      LIMIT 1
    ), source AS (
      SELECT
        provider_row.provider AS provider,
        COALESCE((SELECT value FROM system_configs WHERE key = $2 LIMIT 1), $3::text) AS endpoint,
        (SELECT value FROM system_configs WHERE key = $4 LIMIT 1) AS api_key
      FROM provider_row
      WHERE NOT EXISTS (
        SELECT 1 FROM system_configs WHERE key = $6
      )
    ), inserted AS (
      INSERT INTO ai_provider_credentials (
        name,
        provider,
        endpoint,
        api_key,
        sovereign,
        description,
        inserted_at,
        updated_at
      )
      SELECT
        CONCAT(INITCAP(provider), ' ', $5::text),
        provider,
        endpoint,
        api_key,
        FALSE,
        '',
        now(),
        now()
      FROM source
      RETURNING id
    ), upserted AS (
      INSERT INTO system_configs (key, value, inserted_at, updated_at)
      SELECT $6::text, id::text, now(), now()
      FROM inserted
      ON CONFLICT (key)
      DO UPDATE SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at
      RETURNING 1
    )
    DELETE FROM system_configs
    WHERE key IN ($1, $2, $4)
      AND EXISTS (SELECT 1 FROM inserted)
    """

    repo().query!(query, [
      "#{prefix}.provider",
      "#{prefix}.endpoint",
      default_endpoint,
      "#{prefix}.api_key",
      label,
      "#{prefix}.credential_id"
    ])
  end
end

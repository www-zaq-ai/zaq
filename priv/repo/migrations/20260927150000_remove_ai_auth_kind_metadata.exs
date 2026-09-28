defmodule Zaq.Repo.Migrations.RemoveAiAuthKindMetadata do
  use Ecto.Migration

  def up do
    execute """
    UPDATE ai_provider_credentials
    SET metadata = metadata - 'auth_kind'
    WHERE connect_credential_id IS NOT NULL
      AND metadata ? 'auth_kind'
    """
  end

  def down do
    execute """
    UPDATE ai_provider_credentials ai
    SET metadata = jsonb_set(COALESCE(ai.metadata, '{}'::jsonb), '{auth_kind}',
      to_jsonb(credential.auth_kind), true)
    FROM connect_credentials credential
    WHERE ai.connect_credential_id = credential.id
    """
  end
end

defmodule Zaq.Repo.Migrations.BackfillConnectBackedAiCredentials do
  use Ecto.Migration

  def up do
    ensure_preflight_ready!()

    execute "LOCK TABLE ai_provider_credentials, connect_credentials, connect_grants IN SHARE ROW EXCLUSIVE MODE"

    execute """
    WITH legacy AS (
      SELECT resource_id::bigint AS ai_id, MIN(id) AS grant_id
      FROM connect_grants
      WHERE resource_type = 'ai_provider_credential'
        AND owner_type = 'org'
        AND owner_id IS NULL
        AND auth_kind = 'oauth2'
      GROUP BY resource_id
      HAVING COUNT(*) = 1
    ), sources AS (
      SELECT
        ai.id AS ai_id,
        ai.name AS ai_name,
        ai.provider AS ai_provider,
        ai.api_key AS ai_api_key,
        ai.metadata AS ai_metadata,
        legacy.grant_id,
        source.request_format AS source_request_format,
        source.metadata AS source_metadata,
        source.client_id AS source_client_id,
        source.client_secret AS source_client_secret,
        source.scopes AS source_scopes,
        source.expires_at AS source_expires_at,
        source.issuer AS source_issuer,
        source.private_key AS source_private_key,
        source.key_id AS source_key_id
      FROM ai_provider_credentials ai
      LEFT JOIN legacy ON legacy.ai_id = ai.id
      LEFT JOIN connect_grants old_grant ON old_grant.id = legacy.grant_id
      LEFT JOIN connect_credentials source ON source.id = old_grant.credential_id
      WHERE ai.connect_credential_id IS NULL
    )
    INSERT INTO connect_credentials (
      name, provider, auth_kind, user_level, request_format, metadata,
      client_id, client_secret, scopes, api_key, expires_at,
      issuer, private_key, key_id, personal_credential_policy, secret_binding,
      inserted_at, updated_at
    )
    SELECT
      LEFT('AI ' || ai_id::text || ': ' || ai_name, 255),
      CASE WHEN ai_provider = 'openai_codex' THEN 'openai' ELSE ai_provider END,
      CASE
        WHEN grant_id IS NOT NULL THEN 'oauth2'
        WHEN COALESCE(ai_metadata->>'auth_kind', '') = 'none' THEN 'none'
        ELSE 'api_key'
      END,
      FALSE,
      CASE WHEN grant_id IS NOT NULL THEN COALESCE(source_request_format, 'bearer') ELSE 'bearer' END,
       (CASE WHEN grant_id IS NOT NULL THEN
         jsonb_strip_nulls(jsonb_build_object(
           'authorize_url', source_metadata->'authorize_url',
           'token_url', source_metadata->'token_url',
           'auth_profile', source_metadata->'auth_profile',
           'pkce', source_metadata->'pkce',
           'authorize_params', NULLIF(COALESCE((
             SELECT jsonb_object_agg(entry.key, entry.value)
             FROM jsonb_each(COALESCE(source_metadata->'authorize_params', '{}'::jsonb)) entry
             WHERE entry.key IN (
               'prompt', 'access_type', 'include_granted_scopes', 'login_hint', 'audience'
             )
           ), '{}'::jsonb), '{}'::jsonb)
         ))
       ELSE '{}'::jsonb END) || jsonb_build_object(
         'managed_by', 'ai_provider_credential',
         'ai_provider_credential_id', ai_id
       ),
      source_client_id,
      source_client_secret,
      COALESCE(source_scopes, '{}'),
      NULL,
      source_expires_at,
      source_issuer,
      source_private_key,
      source_key_id,
      'disabled',
      CASE WHEN COALESCE(ai_metadata->>'auth_kind', '') = 'none'
        THEN 'configuration' ELSE 'grant' END,
      now(),
      now()
    FROM sources
    """

    execute """
    UPDATE ai_provider_credentials ai
    SET connect_credential_id = credential.id,
        updated_at = now()
    FROM connect_credentials credential
    WHERE ai.connect_credential_id IS NULL
      AND credential.metadata->>'managed_by' = 'ai_provider_credential'
      AND credential.metadata->>'ai_provider_credential_id' = ai.id::text
    """

    execute """
    UPDATE connect_credentials credential
    SET metadata = credential.metadata - 'managed_by' - 'ai_provider_credential_id',
        updated_at = now()
    FROM ai_provider_credentials ai
    WHERE ai.connect_credential_id = credential.id
      AND credential.metadata->>'managed_by' = 'ai_provider_credential'
      AND credential.metadata->>'ai_provider_credential_id' = ai.id::text
    """

    execute """
    INSERT INTO connect_grants (
      credential_id, provider, auth_kind, resource_type, resource_id,
      owner_type, owner_id, request_format, metadata, expires_at, status,
      access_token, refresh_token, scopes, api_key, issuer, private_key, key_id, subject,
      inserted_at, updated_at
    )
    SELECT
      credential.id,
      credential.provider,
      credential.auth_kind,
      'connect_credential',
      credential.id::text,
      'org',
      NULL,
      credential.request_format,
      '{}'::jsonb,
      NULL,
      'active',
      NULL,
      NULL,
      credential.scopes,
      ai.api_key,
      credential.issuer,
      NULL,
      credential.key_id,
      NULL,
      now(),
      now()
    FROM ai_provider_credentials ai
    JOIN connect_credentials credential ON credential.id = ai.connect_credential_id
    WHERE credential.auth_kind = 'api_key'
      AND NULLIF(BTRIM(ai.api_key), '') IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM connect_grants existing
        WHERE existing.credential_id = credential.id
          AND existing.resource_type = 'connect_credential'
          AND existing.owner_type = 'org'
      )
    """

    execute """
    WITH legacy AS (
      SELECT resource_id::bigint AS ai_id, MIN(id) AS grant_id
      FROM connect_grants
      WHERE resource_type = 'ai_provider_credential'
        AND owner_type = 'org'
        AND owner_id IS NULL
        AND auth_kind = 'oauth2'
      GROUP BY resource_id
      HAVING COUNT(*) = 1
    )
    INSERT INTO connect_grants (
      credential_id, provider, auth_kind, resource_type, resource_id,
      owner_type, owner_id, request_format, metadata, expires_at, status,
      access_token, refresh_token, scopes, api_key, issuer, private_key, key_id, subject,
      refresh_claim, refresh_claim_until, inserted_at, updated_at
    )
    SELECT
      credential.id,
      credential.provider,
      'oauth2',
      'connect_credential',
      credential.id::text,
      'org',
      NULL,
      credential.request_format,
      old.metadata,
      old.expires_at,
      old.status,
      old.access_token,
      old.refresh_token,
      credential.scopes,
      NULL,
      credential.issuer,
      NULL,
      credential.key_id,
      old.subject,
      NULL,
      NULL,
      old.inserted_at,
      old.updated_at
    FROM legacy
    JOIN ai_provider_credentials ai ON ai.id = legacy.ai_id
    JOIN connect_credentials credential ON credential.id = ai.connect_credential_id
    JOIN connect_grants old ON old.id = legacy.grant_id
    WHERE NOT EXISTS (
      SELECT 1 FROM connect_grants existing
      WHERE existing.credential_id = credential.id
        AND existing.resource_type = 'connect_credential'
        AND existing.owner_type = 'org'
    )
    """

    execute "DROP TABLE IF EXISTS zaq_ai_migrated_oauth_sources"

    execute """
    CREATE TEMP TABLE zaq_ai_migrated_oauth_sources ON COMMIT DROP AS
    SELECT grant_row.id AS grant_id, grant_row.credential_id
    FROM connect_grants grant_row
    JOIN ai_provider_credentials ai
      ON grant_row.resource_type = 'ai_provider_credential'
     AND grant_row.resource_id = ai.id::text
    WHERE grant_row.owner_type = 'org'
      AND grant_row.owner_id IS NULL
      AND grant_row.auth_kind = 'oauth2'
      AND ai.connect_credential_id IS NOT NULL
      AND grant_row.credential_id <> ai.connect_credential_id
    """

    execute """
    DELETE FROM connect_grants grant_row
    USING zaq_ai_migrated_oauth_sources source
    WHERE grant_row.id = source.grant_id
    """

    execute """
    DELETE FROM connect_credentials credential
    USING zaq_ai_migrated_oauth_sources source
    WHERE credential.id = source.credential_id
      AND NOT EXISTS (
        SELECT 1 FROM connect_grants grant_row
        WHERE grant_row.credential_id = credential.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM ai_provider_credentials ai
        WHERE ai.connect_credential_id = credential.id
      )
    """

    execute "DROP TABLE zaq_ai_migrated_oauth_sources"

    alter table(:ai_provider_credentials) do
      modify :connect_credential_id, :bigint, null: false
    end
  end

  def down do
    execute "LOCK TABLE ai_provider_credentials, connect_credentials, connect_grants IN ACCESS EXCLUSIVE MODE"

    execute """
    DO $$ BEGIN
      IF EXISTS (
        SELECT 1
        FROM ai_provider_credentials ai
        JOIN connect_credentials credential ON credential.id = ai.connect_credential_id
        WHERE credential.personal_credential_policy <> 'disabled'
           OR EXISTS (
             SELECT 1 FROM connect_grants grant_row
             WHERE grant_row.credential_id = credential.id
               AND grant_row.owner_type = 'person'
           )
      ) THEN
        RAISE EXCEPTION 'cannot roll back Connect-backed AI credentials after personal configuration';
      END IF;
    END $$
    """

    alter table(:ai_provider_credentials) do
      modify :connect_credential_id, :bigint, null: true
    end

    execute "DROP TABLE IF EXISTS zaq_ai_connect_rollback_ids"

    execute """
    CREATE TEMP TABLE zaq_ai_connect_rollback_ids ON COMMIT DROP AS
    SELECT ai.id AS ai_id, ai.connect_credential_id AS id, credential.auth_kind
    FROM ai_provider_credentials ai
    JOIN connect_credentials credential ON credential.id = ai.connect_credential_id
    WHERE ai.connect_credential_id IS NOT NULL
    """

    execute """
    UPDATE connect_grants grant_row
    SET resource_type = 'ai_provider_credential',
        resource_id = rollback.ai_id::text,
        updated_at = now()
    FROM zaq_ai_connect_rollback_ids rollback
    WHERE rollback.auth_kind = 'oauth2'
      AND grant_row.credential_id = rollback.id
      AND grant_row.resource_type = 'connect_credential'
      AND grant_row.owner_type = 'org'
      AND grant_row.owner_id IS NULL
    """

    execute """
    UPDATE connect_credentials credential
    SET name = LEFT('Legacy AI OAuth ' || rollback.ai_id::text || ': ' || credential.name, 255),
        updated_at = now()
    FROM zaq_ai_connect_rollback_ids rollback
    WHERE rollback.auth_kind = 'oauth2'
      AND credential.id = rollback.id
    """

    execute """
    UPDATE ai_provider_credentials ai
    SET api_key = NULL, updated_at = now()
    FROM zaq_ai_connect_rollback_ids rollback
    WHERE ai.id = rollback.ai_id
    """

    execute """
    UPDATE connect_credentials credential
    SET secret_binding = 'configuration', updated_at = now()
    FROM zaq_ai_connect_rollback_ids rollback
    WHERE rollback.auth_kind = 'oauth2'
      AND credential.id = rollback.id
    """

    execute """
    UPDATE ai_provider_credentials
    SET connect_credential_id = NULL, updated_at = now()
    WHERE connect_credential_id IS NOT NULL
    """

    execute """
    DELETE FROM connect_credentials credential
    USING zaq_ai_connect_rollback_ids rollback
    WHERE credential.id = rollback.id
      AND NOT EXISTS (
        SELECT 1 FROM connect_grants grant_row
        WHERE grant_row.credential_id = credential.id
          AND grant_row.resource_type = 'ai_provider_credential'
      )
    """

    execute "DROP TABLE zaq_ai_connect_rollback_ids"
  end

  defp ensure_preflight_ready! do
    do_preflight(0)
  end

  defp do_preflight(after_id) do
    case Zaq.System.AIProviderCredentialMigration.preflight(after_id: after_id, limit: 500) do
      {:ok, %{ready?: true, next_after_id: nil}} ->
        :ok

      {:ok, %{ready?: true, next_after_id: next}} ->
        do_preflight(next)

      {:ok, %{items: items}} ->
        blocked =
          items
          |> Enum.reject(&(&1.classification in [:already_migrated, :api_key, :oauth2, :no_auth]))
          |> Enum.map(&{&1.ai_provider_credential_id, &1.classification, &1.reason})

        raise "AI credential Connect migration preflight failed: #{inspect(blocked)}"

      {:error, reason} ->
        raise "AI credential Connect migration preflight failed: #{inspect(reason)}"
    end
  end
end

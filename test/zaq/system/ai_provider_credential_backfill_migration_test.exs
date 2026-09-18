unless Code.ensure_loaded?(Zaq.Repo.Migrations.AddConnectBackedAiCredentials) do
  Code.require_file(
    "../../../priv/repo/migrations/20260918130000_add_connect_backed_ai_credentials.exs",
    __DIR__
  )
end

unless Code.ensure_loaded?(Zaq.Repo.Migrations.BackfillConnectBackedAiCredentials) do
  Code.require_file(
    "../../../priv/repo/migrations/20260918131000_backfill_connect_backed_ai_credentials.exs",
    __DIR__
  )
end

defmodule Zaq.System.AIProviderCredentialBackfillMigrationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Repo.Migrations.AddConnectBackedAiCredentials
  alias Zaq.Repo.Migrations.BackfillConnectBackedAiCredentials
  alias Zaq.System.SecretConfig

  @association_version 20_260_918_130_000
  @backfill_version 20_260_918_131_000
  @migration_opts [log: false, migration_lock: false, skip_table_creation: true]

  defp migrate(direction, version, module) do
    apply(Ecto.Migrator, direction, [Repo, version, module, @migration_opts])
  end

  test "backfills API-key, explicit no-auth and OAuth rows and preserves rollback sources" do
    assert :ok = migrate(:down, @backfill_version, BackfillConnectBackedAiCredentials)
    assert :ok = migrate(:down, @association_version, AddConnectBackedAiCredentials)

    {:ok, encrypted_api_key} = SecretConfig.encrypt("legacy-api-key")
    {:ok, encrypted_access_token} = SecretConfig.encrypt("legacy-access-token")
    {:ok, encrypted_refresh_token} = SecretConfig.encrypt("legacy-refresh-token")

    api_id = insert_ai("migration-api", encrypted_api_key, %{})
    none_id = insert_ai("migration-none", nil, %{"auth_kind" => "none"})
    oauth_id = insert_ai("migration-oauth", nil, %{})
    source_credential_id = insert_oauth_credential()

    %{rows: [[legacy_grant_id]]} =
      Repo.query!(
        """
        INSERT INTO connect_grants (
          credential_id, provider, auth_kind, resource_type, resource_id,
          owner_type, owner_id, request_format, metadata, status,
          access_token, refresh_token, scopes, inserted_at, updated_at
        ) VALUES ($1, 'openai', 'oauth2', 'ai_provider_credential', $2,
          'org', NULL, 'bearer', '{"account":"legacy"}'::jsonb, 'active',
          $3, $4, ARRAY['openid'], now(), now())
        RETURNING id
        """,
        [
          source_credential_id,
          to_string(oauth_id),
          encrypted_access_token,
          encrypted_refresh_token
        ]
      )

    assert :ok = migrate(:up, @association_version, AddConnectBackedAiCredentials)
    assert :ok = migrate(:up, @backfill_version, BackfillConnectBackedAiCredentials)
    assert :already_up = migrate(:up, @backfill_version, BackfillConnectBackedAiCredentials)

    rows =
      Repo.query!(
        """
        SELECT ai.id, credential.auth_kind, credential.personal_credential_policy,
               credential.secret_binding, grant_row.status, grant_row.api_key,
               grant_row.access_token, grant_row.refresh_token
        FROM ai_provider_credentials ai
        JOIN connect_credentials credential ON credential.id = ai.connect_credential_id
        LEFT JOIN connect_grants grant_row
          ON grant_row.credential_id = credential.id
         AND grant_row.resource_type = 'connect_credential'
         AND grant_row.owner_type = 'org'
        WHERE ai.id = ANY($1)
        ORDER BY ai.id
        """,
        [[api_id, none_id, oauth_id]]
      ).rows

    projected = Map.new(rows, fn [id | values] -> {id, values} end)

    assert ["api_key", "disabled", "grant", "active", ^encrypted_api_key, nil, nil] =
             projected[api_id]

    assert ["none", "disabled", "configuration", nil, nil, nil, nil] = projected[none_id]

    assert [
             "oauth2",
             "disabled",
             "grant",
             "active",
             nil,
             ^encrypted_access_token,
             ^encrypted_refresh_token
           ] = projected[oauth_id]

    assert [[legacy_grant_id, source_credential_id]] ==
             Repo.query!(
               "SELECT id, credential_id FROM connect_grants WHERE id = $1",
               [legacy_grant_id]
             ).rows

    assert [[%{}]] ==
             Repo.query!(
               """
               SELECT credential.metadata
               FROM ai_provider_credentials ai
               JOIN connect_credentials credential ON credential.id = ai.connect_credential_id
               WHERE ai.id = $1
               """,
               [oauth_id]
             ).rows

    generated_ids =
      Repo.query!(
        "SELECT connect_credential_id FROM ai_provider_credentials WHERE id = ANY($1)",
        [[api_id, none_id, oauth_id]]
      ).rows
      |> List.flatten()

    assert :ok = migrate(:down, @backfill_version, BackfillConnectBackedAiCredentials)

    assert [[nil], [nil], [nil]] ==
             Repo.query!(
               "SELECT connect_credential_id FROM ai_provider_credentials WHERE id = ANY($1) ORDER BY id",
               [[api_id, none_id, oauth_id]]
             ).rows

    assert [[legacy_grant_id, source_credential_id]] ==
             Repo.query!(
               "SELECT id, credential_id FROM connect_grants WHERE id = $1",
               [legacy_grant_id]
             ).rows

    assert [[0]] ==
             Repo.query!(
               "SELECT COUNT(*) FROM connect_credentials WHERE id = ANY($1)",
               [generated_ids]
             ).rows

    assert :ok = migrate(:up, @backfill_version, BackfillConnectBackedAiCredentials)
  end

  defp insert_ai(name, api_key, metadata) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO ai_provider_credentials (
          name, provider, endpoint, api_key, metadata, sovereign, inserted_at, updated_at
        ) VALUES ($1, 'openai', 'https://example.test/v1', $2, $3, FALSE, now(), now())
        RETURNING id
        """,
        [name, api_key, metadata]
      )

    id
  end

  defp insert_oauth_credential do
    %{rows: [[id]]} =
      Repo.query!("""
      INSERT INTO connect_credentials (
        name, provider, auth_kind, user_level, request_format, metadata,
        client_id, scopes, personal_credential_policy, secret_binding,
        inserted_at, updated_at
      ) VALUES (
        'migration-oauth-source', 'openai', 'oauth2', FALSE, 'bearer', '{}'::jsonb,
        'client-id', ARRAY['openid'], 'disabled', 'grant', now(), now()
      ) RETURNING id
      """)

    id
  end
end

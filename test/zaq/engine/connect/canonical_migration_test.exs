unless Code.ensure_loaded?(Zaq.Repo.Migrations.AddCanonicalConnectGrantStorage) do
  Code.require_file(
    "../../../../priv/repo/migrations/20260913102416_add_canonical_connect_grant_storage.exs",
    __DIR__
  )
end

defmodule Zaq.Engine.Connect.CanonicalMigrationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.Person
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.Grant
  alias Zaq.Repo.Migrations.AddCanonicalConnectGrantStorage

  @version 20_260_913_102_416

  defp migrate(direction) do
    apply(Ecto.Migrator, direction, [
      Repo,
      @version,
      AddCanonicalConnectGrantStorage,
      [log: false, migration_lock: false, skip_table_creation: true]
    ])
  end

  test "upgrade preserves representative legacy rows; down/up and retry preserve secrets" do
    assert :ok = migrate(:down)

    %{rows: [[credential_id]]} =
      Repo.query!("""
      INSERT INTO connect_credentials (name, provider, auth_kind, inserted_at, updated_at)
      VALUES ('migration-legacy', 'example', 'api_key', now(), now()) RETURNING id
      """)

    for {owner, id} <- [{"org", nil}, {"org", 5}, {"user", 10}],
        status <- ["active", "revoked", "expired"] do
      Repo.query!(
        """
        INSERT INTO connect_grants (credential_id, provider, auth_kind, resource_type,
          resource_id, owner_type, owner_id, status, api_key, inserted_at, updated_at)
        VALUES ($1, 'example', 'api_key', 'mcp', 'legacy', $2, $3, $4, 'opaque-ciphertext', now(), now())
        """,
        [credential_id, owner, id, status]
      )
    end

    before =
      Repo.query!(
        "SELECT id, owner_type, owner_id, status, api_key FROM connect_grants ORDER BY id"
      ).rows

    assert :ok = migrate(:up)
    assert :already_up = migrate(:up)

    assert [["disabled", "configuration"]] ==
             Repo.query!(
               "SELECT personal_credential_policy, secret_binding FROM connect_credentials WHERE id = $1",
               [credential_id]
             ).rows

    assert [["mcp", "legacy"]] ==
             Repo.query!("SELECT DISTINCT resource_type, resource_id FROM connect_grants").rows

    assert :ok = migrate(:down)

    assert before ==
             Repo.query!(
               "SELECT id, owner_type, owner_id, status, api_key FROM connect_grants ORDER BY id"
             ).rows

    assert :ok = migrate(:up)
  end

  test "database independently enforces policy, resource equality and ownership shape" do
    {:ok, config} =
      Connect.create_credential(%{name: "constraints", provider: "example", auth_kind: "api_key"})

    person = Repo.insert!(%Person{full_name: "Owner"})

    {:ok, grant} =
      %Grant{}
      |> Connect.change_credential_grant(
        config,
        %{owner_type: "person", owner_id: person.id, api_key: "secret"}
      )
      |> Repo.insert()

    for {sql, params, code} <- [
          {"UPDATE connect_credentials SET personal_credential_policy = 'invalid' WHERE id = $1",
           [config.id], :check_violation},
          {"UPDATE connect_credentials SET personal_credential_policy = NULL WHERE id = $1",
           [config.id], :not_null_violation},
          {"UPDATE connect_credentials SET secret_binding = 'invalid' WHERE id = $1", [config.id],
           :check_violation},
          {"UPDATE connect_grants SET resource_type = 'invalid' WHERE id = $1", [grant.id],
           :check_violation},
          {"UPDATE connect_grants SET resource_id = 'mixed' WHERE id = $1", [grant.id],
           :check_violation},
          {"UPDATE connect_grants SET resource_type = 'mcp' WHERE id = $1", [grant.id],
           :check_violation},
          {"UPDATE connect_grants SET resource_id = NULL WHERE id = $1", [grant.id],
           :not_null_violation},
          {"UPDATE connect_grants SET resource_type = NULL WHERE id = $1", [grant.id],
           :not_null_violation},
          {"UPDATE connect_grants SET owner_id = NULL WHERE id = $1", [grant.id],
           :check_violation},
          {"UPDATE connect_grants SET owner_type = 'user' WHERE id = $1", [grant.id],
           :check_violation},
          {"UPDATE connect_grants SET owner_type = 'org' WHERE id = $1", [grant.id],
           :check_violation},
          {"UPDATE connect_grants SET credential_id = -1, resource_id = '-1' WHERE id = $1",
           [grant.id], :foreign_key_violation}
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: ^code}}} =
               Repo.query(sql, params, mode: :savepoint)
    end
  end
end

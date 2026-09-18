unless Code.ensure_loaded?(Zaq.Repo.Migrations.CreateConnectOauthAttempts) do
  Code.require_file(
    "../../../../priv/repo/migrations/20260914103711_create_connect_oauth_attempts.exs",
    __DIR__
  )
end

unless Code.ensure_loaded?(Zaq.Repo.Migrations.BindConnectOauthAttemptsToPersonSessions) do
  Code.require_file(
    "../../../../priv/repo/migrations/20260917121000_bind_connect_oauth_attempts_to_person_sessions.exs",
    __DIR__
  )
end

defmodule Zaq.Engine.Connect.OAuthAttemptsMigrationTest do
  use Zaq.DataCase, async: false
  alias Zaq.Accounts.Person
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{OAuthAttempt, PersonCredentials}
  alias Zaq.Repo.Migrations.BindConnectOauthAttemptsToPersonSessions
  alias Zaq.Repo.Migrations.CreateConnectOauthAttempts

  defp migrate(direction) do
    apply(Ecto.Migrator, direction, [
      Repo,
      20_260_914_103_711,
      CreateConnectOauthAttempts,
      [log: false, migration_lock: false, skip_table_creation: true]
    ])
  end

  defp migrate_session(direction) do
    apply(Ecto.Migrator, direction, [
      Repo,
      20_260_917_121_000,
      BindConnectOauthAttemptsToPersonSessions,
      [log: false, migration_lock: false, skip_table_creation: true]
    ])
  end

  test "down/up is reversible and database enforces attempt owner shape plus credential FK" do
    assert :ok = migrate_session(:down)
    assert :ok = migrate(:down)
    assert %{rows: [[nil]]} = Repo.query!("SELECT to_regclass('connect_oauth_attempts')")
    assert :ok = migrate(:up)
    assert :ok = migrate_session(:up)
    assert :already_up = migrate(:up)

    person = Repo.insert!(Person.changeset(%Person{}, %{full_name: "Attempt migration"}))

    {:ok, dto} =
      Connect.save_credential_configuration(nil, %{
        name: Ecto.UUID.generate(),
        provider: "example",
        auth_kind: "oauth2",
        client_id: "client",
        secret_binding: :grant,
        personal_credential_policy: :required,
        metadata: %{
          "authorize_url" => "https://provider.example/auth",
          "token_url" => "https://provider.example/token"
        }
      })

    {:ok, _} = PersonCredentials.start_oauth(person, dto.credential_id)
    attempt = Repo.get_by!(OAuthAttempt, credential_id: dto.credential_id)

    for {assignment, code} <- [
          {"owner_id = NULL", :check_violation},
          {"owner_type = 'user'", :check_violation},
          {"owner_type = 'org'", :check_violation},
          {"credential_id = NULL", :check_violation},
          {"credential_id = -1", :foreign_key_violation},
          {"candidate_config = 'untrusted'", :check_violation},
          {"expires_at = NULL", :not_null_violation}
        ] do
      sql = "UPDATE connect_oauth_attempts SET #{assignment} WHERE id = $1"

      assert {:error, %Postgrex.Error{postgres: %{code: ^code}}} =
               Repo.query(sql, [attempt.id], mode: :savepoint)
    end

    {:ok, credential} = Connect.fetch_credential(dto.credential_id)
    {:ok, _} = Connect.delete_credential(credential)
    refute Repo.get(OAuthAttempt, attempt.id)
  end
end

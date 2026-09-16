defmodule Zaq.Repo.Migrations.CreatePersonAuthentication do
  use Ecto.Migration

  def change do
    # NormalizePersonEmails invokes the current PersonMerger on fresh installs.
    # Its authentication dependencies must exist before that data migration runs.
    # Existing installations apply this pending version with ordinary ecto.migrate.
    create table(:person_login_challenges, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :person_id, references(:people, on_delete: :delete_all), null: false
      add :token_digest, :binary, null: false
      add :expires_at, :utc_datetime, null: false
      add :attempt_count, :integer, null: false, default: 0
      add :consumed_at, :utc_datetime
      add :invalidated_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:person_login_challenges, [:person_id],
             name: :person_login_challenges_active_person_index,
             where: "consumed_at IS NULL AND invalidated_at IS NULL"
           )

    create index(:person_login_challenges, [:person_id])
    create index(:person_login_challenges, [:expires_at])

    create constraint(:person_login_challenges, :person_login_challenges_attempt_count_check,
             check: "attempt_count >= 0"
           )

    create constraint(:person_login_challenges, :person_login_challenges_lifecycle_check,
             check: "consumed_at IS NULL OR invalidated_at IS NULL"
           )

    create constraint(:person_login_challenges, :person_login_challenges_digest_check,
             check: "octet_length(token_digest) = 32"
           )

    create constraint(:person_login_challenges, :person_login_challenges_expiry_check,
             check: "expires_at > inserted_at"
           )

    create table(:person_sessions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :person_id, references(:people, on_delete: :delete_all), null: false
      add :token_digest, :binary, null: false
      add :expires_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime
      add :last_seen_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:person_sessions, [:token_digest])
    create index(:person_sessions, [:person_id])
    create index(:person_sessions, [:expires_at])
    create index(:person_sessions, [:revoked_at], where: "revoked_at IS NOT NULL")

    create constraint(:person_sessions, :person_sessions_digest_check,
             check: "octet_length(token_digest) = 32"
           )

    create constraint(:person_sessions, :person_sessions_expiry_check,
             check: "expires_at > inserted_at"
           )
  end
end

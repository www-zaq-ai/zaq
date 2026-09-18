defmodule Zaq.Repo.Migrations.BindConnectOauthAttemptsToPersonSessions do
  use Ecto.Migration

  def up do
    alter table(:connect_oauth_attempts) do
      add :session_id, references(:person_sessions, type: :uuid, on_delete: :delete_all)
    end

    create index(:connect_oauth_attempts, [:session_id])
  end

  def down do
    alter table(:connect_oauth_attempts) do
      remove :session_id
    end
  end
end

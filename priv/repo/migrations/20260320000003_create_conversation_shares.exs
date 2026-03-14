defmodule Zaq.Repo.Migrations.CreateConversationShares do
  use Ecto.Migration

  def change do
    create table(:conversation_shares, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :shared_with_user_id, references(:users, on_delete: :nilify_all), null: true
      add :share_token, :string, null: false
      add :permission, :string, null: false, default: "read"
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:conversation_shares, [:share_token])

    create unique_index(:conversation_shares, [:conversation_id, :shared_with_user_id],
             where: "shared_with_user_id IS NOT NULL"
           )
  end
end

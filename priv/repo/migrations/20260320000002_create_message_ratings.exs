defmodule Zaq.Repo.Migrations.CreateMessageRatings do
  use Ecto.Migration

  def change do
    create table(:message_ratings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :message_id, references(:messages, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, on_delete: :nilify_all), null: true
      add :channel_user_id, :string
      add :rating, :integer, null: false
      add :comment, :text

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:message_ratings, [:message_id])
    create unique_index(:message_ratings, [:message_id, :user_id], where: "user_id IS NOT NULL")
  end
end

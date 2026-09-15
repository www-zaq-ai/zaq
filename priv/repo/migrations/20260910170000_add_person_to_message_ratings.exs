defmodule Zaq.Repo.Migrations.AddPersonToMessageRatings do
  use Ecto.Migration

  def change do
    # Historical email normalization invokes the current PersonMerger.
    alter table(:message_ratings) do
      add :person_id, references(:people, on_delete: :delete_all)
    end

    create index(:message_ratings, [:person_id])

    create unique_index(:message_ratings, [:message_id, :person_id],
             where: "person_id IS NOT NULL"
           )

    create constraint(:message_ratings, :person_rating_actor,
             check: "person_id IS NULL OR (user_id IS NULL AND channel_user_id IS NULL)"
           )
  end
end

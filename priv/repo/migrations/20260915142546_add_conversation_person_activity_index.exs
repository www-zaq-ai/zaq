defmodule Zaq.Repo.Migrations.AddConversationPersonActivityIndex do
  use Ecto.Migration

  def change do
    # Backward index scans serve the literal owner's updated_at/id DESC pages.
    create index(:conversations, [:person_id, :updated_at, :id],
             name: :conversations_person_activity_index
           )
  end
end

defmodule Zaq.Repo.Migrations.AddLabelAssignmentValues do
  use Ecto.Migration

  def change do
    alter table(:document_label_assignments) do
      add :value, :text
    end

    alter table(:chunk_label_assignments) do
      add :value, :text
    end
  end
end

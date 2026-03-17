defmodule Zaq.Repo.Migrations.MakeDocumentContentNullable do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      modify :content, :text, null: true
    end
  end
end

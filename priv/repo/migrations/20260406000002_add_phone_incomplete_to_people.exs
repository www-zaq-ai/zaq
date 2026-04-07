defmodule Zaq.Repo.Migrations.AddPhoneIncompleteToPeople do
  use Ecto.Migration

  def change do
    alter table(:people) do
      add :phone, :string
      add :incomplete, :boolean, default: true, null: false
    end
  end
end

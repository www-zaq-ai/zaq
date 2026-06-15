defmodule Zaq.Repo.Migrations.AddPortalConsentToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :portal_consent, :string
    end
  end
end

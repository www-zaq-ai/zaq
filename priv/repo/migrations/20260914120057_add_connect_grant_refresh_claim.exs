defmodule Zaq.Repo.Migrations.AddConnectGrantRefreshClaim do
  use Ecto.Migration

  def change do
    alter table(:connect_grants) do
      add :refresh_claim, :uuid
      add :refresh_claim_until, :utc_datetime
    end
  end
end

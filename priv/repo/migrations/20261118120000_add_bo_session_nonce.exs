defmodule Zaq.Repo.Migrations.AddBOSessionNonce do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :bo_session_nonce, :uuid
    end
  end
end

defmodule Zaq.Repo.Migrations.GuardArchivedConnectorActivation do
  use Ecto.Migration

  def change do
    create constraint(:channel_configs, :archived_configs_disabled,
             check: "archived_at IS NULL OR enabled = false"
           )
  end
end

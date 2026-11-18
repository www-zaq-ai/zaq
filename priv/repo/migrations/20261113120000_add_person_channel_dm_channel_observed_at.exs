defmodule Zaq.Repo.Migrations.AddPersonChannelDmChannelObservedAt do
  use Ecto.Migration

  def change do
    alter table(:channels) do
      add :dm_channel_observed_at, :utc_datetime_usec
    end
  end
end

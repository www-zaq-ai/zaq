defmodule Zaq.Repo.Migrations.AddPreferredChannelToPeople do
  use Ecto.Migration

  # Column added by license_manager migration 20260305073423.
  # Stamp only — the column exists in prod/dev but is not mapped by Zaq.Accounts.Person.
  # Preferred channel is determined by weight (weight 0 = preferred), not by this FK.
  def up, do: execute("SELECT 1")
  def down, do: :ok
end

defmodule Zaq.Repo.Migrations.CreateMcpEndpoints do
  use Ecto.Migration

  def change do
    create table(:mcp_endpoints) do
      add :name, :string, null: false
      add :type, :string, null: false
      add :status, :string, null: false, default: "disabled"
      add :timeout_ms, :integer, null: false, default: 5000

      add :command, :text
      add :args, {:array, :string}, null: false, default: []

      add :url, :text
      add :headers, :map, null: false, default: %{}
      add :secret_headers, :map, null: false, default: %{}
      add :environments, :map, null: false, default: %{}
      add :secret_environments, :map, null: false, default: %{}

      add :settings, :map, null: false, default: %{}
      add :predefined_id, :string

      timestamps(type: :utc_datetime)
    end

    create index(:mcp_endpoints, [:name])
    create index(:mcp_endpoints, [:type])
    create index(:mcp_endpoints, [:status])
    create unique_index(:mcp_endpoints, [:predefined_id], where: "predefined_id IS NOT NULL")
  end
end

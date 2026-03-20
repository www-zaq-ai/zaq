defmodule Zaq.Repo.Migrations.CreateTelemetryTables do
  use Ecto.Migration

  def change do
    create table(:telemetry_points) do
      add :metric_key, :string, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      add :value, :float, null: false
      add :dimensions, :map, null: false, default: %{}
      add :dimension_key, :string, null: false
      add :source, :string, null: false, default: "local"
      add :node, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:telemetry_points, [:metric_key, :occurred_at])
    create index(:telemetry_points, [:source, :occurred_at])
    create index(:telemetry_points, [:dimension_key])

    create table(:telemetry_rollups) do
      add :metric_key, :string, null: false
      add :bucket_start, :utc_datetime_usec, null: false
      add :bucket_size, :string, null: false
      add :source, :string, null: false, default: "local"
      add :dimensions, :map, null: false, default: %{}
      add :dimension_key, :string, null: false

      add :value_sum, :float, null: false, default: 0.0
      add :value_count, :integer, null: false, default: 0
      add :value_min, :float, null: false, default: 0.0
      add :value_max, :float, null: false, default: 0.0
      add :last_value, :float, null: false, default: 0.0
      add :last_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :telemetry_rollups,
             [:metric_key, :bucket_start, :bucket_size, :source, :dimension_key],
             name: :telemetry_rollups_identity_idx
           )

    create index(:telemetry_rollups, [:metric_key, :bucket_size, :bucket_start])
    create index(:telemetry_rollups, [:source, :bucket_size, :bucket_start])

    execute(
      "CREATE INDEX telemetry_points_dimensions_gin_idx ON telemetry_points USING gin (dimensions)"
    )

    execute(
      "CREATE INDEX telemetry_rollups_dimensions_gin_idx ON telemetry_rollups USING gin (dimensions)"
    )
  end
end

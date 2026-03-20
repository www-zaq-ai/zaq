defmodule Zaq.Engine.Telemetry.Rollup do
  @moduledoc """
  Materialized telemetry aggregates by metric and time bucket.

  Rows are upserted by background workers and queried by dashboard loaders.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "telemetry_rollups" do
    field :metric_key, :string
    field :bucket_start, :utc_datetime_usec
    field :bucket_size, :string
    field :source, :string, default: "local"
    field :dimensions, :map, default: %{}
    field :dimension_key, :string

    field :value_sum, :float, default: 0.0
    field :value_count, :integer, default: 0
    field :value_min, :float, default: 0.0
    field :value_max, :float, default: 0.0
    field :last_value, :float, default: 0.0
    field :last_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Returns a validated changeset for a rollup row."
  def changeset(rollup, attrs) do
    rollup
    |> cast(attrs, [
      :metric_key,
      :bucket_start,
      :bucket_size,
      :source,
      :dimensions,
      :dimension_key,
      :value_sum,
      :value_count,
      :value_min,
      :value_max,
      :last_value,
      :last_at
    ])
    |> validate_required([
      :metric_key,
      :bucket_start,
      :bucket_size,
      :source,
      :dimension_key,
      :last_at
    ])
  end
end

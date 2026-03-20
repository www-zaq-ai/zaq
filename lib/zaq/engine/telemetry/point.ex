defmodule Zaq.Engine.Telemetry.Point do
  @moduledoc """
  Raw telemetry point captured from runtime events.

  This table is append-only and optimized for write throughput.
  Rollups are materialized asynchronously by Oban workers.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "telemetry_points" do
    field :metric_key, :string
    field :occurred_at, :utc_datetime_usec
    field :value, :float
    field :dimensions, :map, default: %{}
    field :dimension_key, :string
    field :source, :string, default: "local"
    field :node, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Returns a validated changeset for a telemetry point."
  def changeset(point, attrs) do
    point
    |> cast(attrs, [
      :metric_key,
      :occurred_at,
      :value,
      :dimensions,
      :dimension_key,
      :source,
      :node
    ])
    |> validate_required([:metric_key, :occurred_at, :value, :dimension_key, :source])
  end
end

defmodule Zaq.System.TelemetryConfig do
  @moduledoc """
  Embedded schema for validating telemetry collection configuration.
  """

  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :capture_infra_metrics, :boolean, default: false
    field :request_duration_threshold_ms, :integer, default: 10
    field :repo_query_duration_threshold_ms, :integer, default: 5
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :capture_infra_metrics,
      :request_duration_threshold_ms,
      :repo_query_duration_threshold_ms
    ])
    |> validate_number(:request_duration_threshold_ms, greater_than_or_equal_to: 0)
    |> validate_number(:repo_query_duration_threshold_ms, greater_than_or_equal_to: 0)
  end
end

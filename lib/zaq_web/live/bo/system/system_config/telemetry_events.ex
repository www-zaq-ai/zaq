defmodule ZaqWeb.Live.BO.System.SystemConfig.TelemetryEvents do
  @moduledoc """
  Helpers for telemetry form assign/update flows.
  """

  alias Zaq.System.TelemetryConfig

  def validate_form(socket, cfg, params) do
    changeset =
      cfg
      |> TelemetryConfig.changeset(params)
      |> Map.put(:action, :validate)

    Phoenix.Component.assign(
      socket,
      :telemetry_form,
      Phoenix.Component.to_form(changeset, as: :telemetry_config)
    )
  end

  def apply_save_error(socket, %Ecto.Changeset{} = changeset) do
    Phoenix.Component.assign(
      socket,
      :telemetry_form,
      Phoenix.Component.to_form(Map.put(changeset, :action, :validate), as: :telemetry_config)
    )
  end
end

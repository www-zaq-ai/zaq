defmodule ZaqWeb.Live.BO.System.SystemConfig.TelemetryEventsTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias ZaqWeb.Live.BO.System.SystemConfig.TelemetryEvents

  test "apply_save_error/2 assigns telemetry form" do
    socket = %Socket{assigns: %{__changed__: %{}}}
    changeset = %Ecto.Changeset{action: :validate}

    updated = TelemetryEvents.apply_save_error(socket, changeset)

    assert %Phoenix.HTML.Form{} = updated.assigns.telemetry_form
  end
end

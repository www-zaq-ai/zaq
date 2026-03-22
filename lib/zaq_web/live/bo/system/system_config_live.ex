defmodule ZaqWeb.Live.BO.System.SystemConfigLive do
  use ZaqWeb, :live_view

  alias Zaq.System
  alias Zaq.System.TelemetryConfig

  def mount(_params, _session, socket) do
    config = System.get_telemetry_config()
    changeset = TelemetryConfig.changeset(config, %{})

    {:ok,
     socket
     |> assign(:current_path, "/bo/system-config")
     |> assign(:page_title, "System Configuration")
     |> assign(:telemetry_form, to_form(changeset, as: :telemetry_config))
     |> assign(:save_status, :idle)}
  end

  def handle_event("validate", %{"telemetry_config" => params}, socket) do
    config = System.get_telemetry_config()

    changeset =
      config
      |> TelemetryConfig.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:telemetry_form, to_form(changeset, as: :telemetry_config))
     |> assign(:save_status, :idle)}
  end

  def handle_event("save", %{"telemetry_config" => params}, socket) do
    config = System.get_telemetry_config()
    changeset = TelemetryConfig.changeset(config, params)

    case System.save_telemetry_config(changeset) do
      {:ok, _} ->
        fresh_changeset = TelemetryConfig.changeset(System.get_telemetry_config(), %{})

        {:noreply,
         socket
         |> put_flash(:info, "Telemetry settings saved.")
         |> assign(:save_status, :ok)
         |> assign(:telemetry_form, to_form(fresh_changeset, as: :telemetry_config))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(
           :telemetry_form,
           to_form(Map.put(changeset, :action, :validate), as: :telemetry_config)
         )
         |> assign(:save_status, {:error, "Please fix the errors below."})}
    end
  end
end

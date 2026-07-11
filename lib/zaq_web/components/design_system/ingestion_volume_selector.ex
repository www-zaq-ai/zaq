defmodule ZaqWeb.Components.DesignSystem.IngestionVolumeSelector do
  @moduledoc """
  Source toggle row for the BO ingestion file browser chrome band.

  Local volumes and external data sources share one `DesignSystem.Toggle` segmented control.
  Values are `volume:<name>` or `provider:<id>`; the LiveView handles navigation via
  `switch_source`.

  **Layout / tokens:** `.zaq-ingestion-chrome-row`, `.zaq-ingestion-meta-label` in
  `assets/css/styles.css`; toggle segments use `.zaq-toggle-*` in the same file.
  """

  use Phoenix.Component

  alias ZaqWeb.Components.DesignSystem.Toggle

  attr :volumes, :map, required: true
  attr :current_volume, :string, required: true
  attr :current_provider, :string, default: "local"
  attr :data_sources, :list, default: []

  def volume_selector(assigns) do
    assigns =
      assigns
      |> assign(:source_value, current_source_value(assigns))
      |> assign(:source_choices, source_choices(assigns))

    ~H"""
    <div class="zaq-ingestion-chrome-row">
      <p class="zaq-ingestion-meta-label zaq-text-caption">
        Sources
      </p>
      <Toggle.toggle
        value={@source_value}
        event="switch_source"
        value_param="source"
        choices={@source_choices}
      />
    </div>
    """
  end

  defp current_source_value(%{current_provider: "local", current_volume: volume}) do
    "volume:#{volume}"
  end

  defp current_source_value(%{current_provider: provider}) do
    "provider:#{provider}"
  end

  defp source_choices(assigns) do
    volume_choices =
      assigns.volumes
      |> Enum.sort()
      |> Enum.map(fn {name, _path} ->
        %{
          value: "volume:#{name}",
          label: name,
          title: name,
          provider: "zaq_local"
        }
      end)

    provider_choices =
      Enum.map(assigns.data_sources, fn source ->
        %{
          value: "provider:#{source.id}",
          label: source.label,
          title: source.label,
          provider: source.id
        }
      end)

    volume_choices ++ provider_choices
  end
end

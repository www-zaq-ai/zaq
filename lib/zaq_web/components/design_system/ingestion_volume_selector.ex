defmodule ZaqWeb.Components.DesignSystem.IngestionVolumeSelector do
  @moduledoc """
  Volume toggle row for the BO ingestion file browser chrome band.

  **Layout / tokens:** uses the shared ingestion chrome pattern in `assets/css/styles.css`
  (`.zaq-ingestion-chrome-row`, `.zaq-ingestion-chrome-actions--compact`, `.zaq-ingestion-meta-label`, `.zaq-ingestion-chip*`)
  composed with `.zaq-text-caption` from `text-styles.css` (no bespoke type scale in `styles.css`).
  """

  use Phoenix.Component

  attr :volumes, :map, required: true
  attr :current_volume, :string, required: true

  def volume_selector(assigns) do
    ~H"""
    <div class="zaq-ingestion-chrome-row">
      <p class="zaq-ingestion-meta-label zaq-text-caption">
        Volume
      </p>
      <div class="zaq-ingestion-chrome-actions zaq-ingestion-chrome-actions--compact">
        <button
          :for={{name, _path} <- Enum.sort(@volumes)}
          phx-click="switch_volume"
          phx-value-volume={name}
          class={[
            "zaq-ingestion-chip zaq-text-caption",
            @current_volume == name && "zaq-ingestion-chip--active"
          ]}
        >
          {name}
        </button>
      </div>
    </div>
    """
  end
end

defmodule ZaqWeb.Components.DesignSystem.IngestionVolumeSelector do
  @moduledoc """
  Volume toggle row for the BO ingestion file browser chrome band.

  **Layout / tokens:** uses the shared ingestion chrome pattern in `assets/css/styles.css`
  (`.zaq-ingestion-chrome-row`, `.zaq-ingestion-chrome-actions--compact`, `.zaq-ingestion-meta-label`)
  and compact toolbar buttons: `.zaq-btn` + `.zaq-btn-tertiary*` in `assets/css/btn.css`
  composed with `.zaq-btn-text_label-default` on volume toggle buttons and `.zaq-text-caption` on the meta label from `text-styles.css` (no bespoke type scale in `styles.css`).
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
          type="button"
          phx-click="switch_volume"
          phx-value-volume={name}
          class={[
            "zaq-btn zaq-btn-tertiary zaq-btn-text_label-default",
            @current_volume == name && "zaq-btn-tertiary--active"
          ]}
        >
          {name}
        </button>
      </div>
    </div>
    """
  end
end

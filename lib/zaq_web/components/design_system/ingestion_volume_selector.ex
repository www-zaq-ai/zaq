defmodule ZaqWeb.Components.DesignSystem.IngestionVolumeSelector do
  @moduledoc """
  Source toggle row for the BO ingestion file browser chrome band.

  **Layout / tokens:** uses the shared ingestion chrome pattern in `assets/css/styles.css`
  (`.zaq-ingestion-chrome-row`, `.zaq-ingestion-chrome-actions--compact`, `.zaq-ingestion-meta-label`)
  and compact toolbar buttons: `.zaq-btn` + `.zaq-btn-tertiary*` in `assets/css/btn.css`
  composed with `.zaq-btn-text_label-default` on volume toggle buttons and `.zaq-text-caption` on the meta label from `text-styles.css` (no bespoke type scale in `styles.css`).
  """

  use Phoenix.Component

  attr :volumes, :map, required: true
  attr :current_volume, :string, required: true
  attr :current_provider, :string, default: "local"
  attr :data_sources, :list, default: []

  def volume_selector(assigns) do
    ~H"""
    <div class="zaq-ingestion-chrome-row">
      <p class="zaq-ingestion-meta-label zaq-text-caption">
        Sources
      </p>
      <div class="zaq-ingestion-chrome-actions zaq-ingestion-chrome-actions--compact">
        <%= for {name, _path} <- Enum.sort(@volumes) do %>
          <button
            :if={@current_provider == "local"}
            type="button"
            phx-click="switch_volume"
            phx-value-volume={name}
            class={[
              "zaq-btn zaq-btn-tertiary zaq-btn-text_label-default",
              @current_volume == name && "zaq-btn-tertiary--active"
            ]}
          >
            <ZaqWeb.Components.ChannelIcons.icon provider="zaq_local" class="zaq-icon-sm" />
            <span>{name}</span>
          </button>
          <.link
            :if={@current_provider != "local"}
            navigate="/bo/ingestion"
            class="zaq-btn zaq-btn-tertiary zaq-btn-text_label-default"
          >
            <ZaqWeb.Components.ChannelIcons.icon provider="zaq_local" class="zaq-icon-sm" />
            <span>{name}</span>
          </.link>
        <% end %>
        <.link
          :for={source <- @data_sources}
          navigate={source.path}
          class={[
            "zaq-btn zaq-btn-tertiary zaq-btn-text_label-default",
            @current_provider == source.id && "zaq-btn-tertiary--active"
          ]}
        >
          <ZaqWeb.Components.ChannelIcons.icon provider={source.id} class="zaq-icon-sm" />
          <span>{source.label}</span>
        </.link>
      </div>
    </div>
    """
  end
end

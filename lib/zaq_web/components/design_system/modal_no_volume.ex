defmodule ZaqWeb.Components.DesignSystem.ModalNoVolume do
  @moduledoc """
  Dead-end notice shown when an action needs an ingestion volume and none is connected.

  Built on `BOModal.modal_shell/1` rather than `confirm_dialog/1`: there is nothing to
  confirm and no destructive action to accept — the operator can only acknowledge and go
  connect a volume. It reuses the centered confirm layout classes with the warning badge
  modifier, so it reads as "blocked", not "about to delete something".
  """

  use Phoenix.Component

  import ZaqWeb.Components.BOModal
  import ZaqWeb.CoreComponents, only: [icon: 1]

  attr :id, :string, default: "no-volume-modal"
  attr :cancel_event, :string, default: "close_resource_modal"
  attr :title, :string, default: "No volume connected"
  attr :message, :string, default: "Please, connect a volume to be able upload a resource"
  attr :close_label, :string, default: "Close"

  def modal_no_volume(assigns) do
    ~H"""
    <.modal_shell
      id={@id}
      cancel_event={@cancel_event}
      max_width_class="zaq-modal--width-sm"
      panel_class="zaq-modal--centered"
      role="dialog"
      aria-modal="true"
      aria-label={@title}
    >
      <div class="zaq-modal-confirm-icon-badge zaq-modal-confirm-icon-badge--warning">
        <.icon name="hero-exclamation-triangle" class="zaq-icon-md" />
      </div>
      <div class="zaq-layout-stack-tight zaq-modal-confirm-copy">
        <h3 class="zaq-text-h3" style="color: var(--zaq-text-color-body-default)">{@title}</h3>
        <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-tertiary)">
          {@message}
        </p>
      </div>
      <div class="zaq-modal-confirm-actions">
        <button
          type="button"
          id={"#{@id}-close"}
          phx-click={@cancel_event}
          class="zaq-btn zaq-btn-secondary zaq-btn-text_label-default"
        >
          {@close_label}
        </button>
      </div>
    </.modal_shell>
    """
  end
end

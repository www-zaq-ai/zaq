defmodule ZaqWeb.Components.DesignSystem.ModalDeleteSelected do
  @moduledoc """
  BO ingestion bulk-delete confirmation (BOModal wrapper).
  """

  use Phoenix.Component

  attr :selected, :any, required: true

  def modal_delete_selected(assigns) do
    ~H"""
    <ZaqWeb.Components.BOModal.confirm_dialog
      id="delete-selected-modal"
      title="Delete Selected"
      message={"Permanently delete #{MapSet.size(@selected)} item(s)."}
      cancel_event="close_modal"
      confirm_event="confirm_delete_selected"
      confirm_label={"Delete All (#{MapSet.size(@selected)})"}
      confirm_button_id="confirm-delete-selected-button"
      max_width_class="max-w-md"
    />
    """
  end
end

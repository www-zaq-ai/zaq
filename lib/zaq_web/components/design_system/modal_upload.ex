defmodule ZaqWeb.Components.DesignSystem.ModalUpload do
  @moduledoc """
  BO ingestion upload modal — wraps `Dropzone.upload_section/1` in `BOModal.form_dialog/1`.
  """

  use Phoenix.Component

  import ZaqWeb.Components.BOModal
  import ZaqWeb.Components.DesignSystem.Dropzone, only: [upload_section: 1]

  attr :uploads, :any, required: true
  attr :embedding_ready, :boolean, default: true
  attr :folder_drop_skipped, :list, default: []
  attr :id, :string, default: "upload-modal"
  attr :title, :string, default: "Upload data"
  attr :cancel_event, :string, default: "close_modal"

  def modal_upload(assigns) do
    ~H"""
    <.form_dialog
      id={@id}
      cancel_event={@cancel_event}
      title={@title}
      max_width_class="zaq-modal--width-xl"
    >
      <.upload_section
        uploads={@uploads}
        embedding_ready={@embedding_ready}
        folder_drop_skipped={@folder_drop_skipped}
      />
    </.form_dialog>
    """
  end
end

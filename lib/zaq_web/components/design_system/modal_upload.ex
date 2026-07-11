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

  def modal_upload(assigns) do
    ~H"""
    <.form_dialog
      id="upload-modal"
      cancel_event="close_modal"
      title="Upload data"
      max_width_class="max-w-xl"
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

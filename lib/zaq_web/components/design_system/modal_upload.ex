defmodule ZaqWeb.Components.DesignSystem.ModalUpload do
  @moduledoc """
  BO upload modal — wraps `Dropzone.upload_section/1` in `BOModal.form_dialog/1`.

  Built for the ingestion page and still defaulting to its ids, events and copy, so
  `IngestionLive` renders identically without passing anything beyond `uploads`. Every
  other surface configures it:

    * **volume picker** — `volumes`; renders only when more than one is configured, so a
      single-volume deployment never sees a control with one option
    * **destination preview** — `destination`; renders only when given
    * **description** — optional intro copy above the dropzone (workflows import)
    * **error** — optional server-side failure banner (workflows JSON validation, etc.)
    * **footer actions** — Cancel plus primary submit (wired to the dropzone form via
      `form={id_prefix}-form`); submit shows `{submit_label} N file(s)` and stays disabled
      until at least one file is queued
    * **dropzone wiring** — `upload_name`, `id_prefix`, the three event names, the two
      labels, `hint`, `too_large_message` and `folder_drop?` are forwarded straight
      through, because two dropzones in one DOM must not share element ids

  Each is off or ingestion-shaped by default. Configure it; do not fork it — skills and
  workflows need the same dialog with different wiring, not a second modal.
  """

  use Phoenix.Component

  alias ZaqWeb.Components.DesignSystem.Button, as: DSButton

  import ZaqWeb.Components.BOModal

  import ZaqWeb.Components.DesignSystem.Dropzone,
    only: [upload_section: 1, default_hint: 0, submit_button_label: 2]

  import ZaqWeb.CoreComponents, only: [icon: 1]
  import ZaqWeb.Select, only: [select: 1]

  attr :uploads, :any, required: true
  attr :id, :string, default: "upload-modal"
  attr :title, :string, default: "Upload data"
  attr :cancel_event, :string, default: "close_modal"
  attr :cancel_label, :string, default: "Cancel"

  attr :description, :string,
    default: nil,
    doc: "Optional intro copy shown above the dropzone."

  attr :error, :string,
    default: nil,
    doc: "Optional server-side failure message (import validation, etc.)."

  # Ingestion-only chrome inside the dropzone.
  attr :embedding_ready, :boolean, default: true
  attr :folder_drop_skipped, :list, default: []

  # Optional volume picker.
  attr :volumes, :map,
    default: %{},
    doc: "`%{name => abs_path}`. The picker appears only with more than one entry."

  attr :current_volume, :string, default: nil
  attr :volume_event, :string, default: "select_volume"

  attr :destination, :string,
    default: nil,
    doc: "Volume-relative path files land in. Shown above the dropzone when set."

  # Forwarded to `Dropzone.upload_section/1` — defaults match its own.
  attr :upload_name, :atom, default: :files
  attr :id_prefix, :string, default: "upload"
  attr :submit_event, :string, default: "upload"
  attr :change_event, :string, default: "validate_upload"
  attr :file_cancel_event, :string, default: "cancel_upload"
  attr :label, :string, default: "Upload"
  attr :submit_label, :string, default: "Upload"
  attr :hint, :string, default: nil

  attr :input_accept, :string,
    default: nil,
    doc: "Optional browser file-picker accept override passed to Dropzone."

  attr :too_large_message, :string, default: "File exceeds 20 MB limit."
  attr :folder_drop?, :boolean, default: true

  slot :form_fields, doc: "Optional fields rendered inside the upload form before the dropzone."

  def modal_upload(assigns) do
    upload = Map.fetch!(assigns.uploads, assigns.upload_name)
    entry_count = length(upload.entries)

    assigns =
      assigns
      |> assign(:volume_options, volume_options(assigns.volumes))
      |> assign(:form_id, "#{assigns.id_prefix}-form")
      |> assign(:submit_button_id, "#{assigns.id_prefix}-files-button")
      |> assign(:submit_button_label, submit_button_label(assigns.submit_label, upload.entries))
      |> assign(:submit_disabled, entry_count == 0 or not assigns.embedding_ready)

    ~H"""
    <.form_dialog
      id={@id}
      cancel_event={@cancel_event}
      title={@title}
      max_width_class="zaq-modal--width-xl"
    >
      <:actions>
        <DSButton.button variant={:secondary} phx-click={@cancel_event}>
          {@cancel_label}
        </DSButton.button>
        <DSButton.button
          variant={:primary}
          type="submit"
          form={@form_id}
          id={@submit_button_id}
          disabled={@submit_disabled}
        >
          {@submit_button_label}
        </DSButton.button>
      </:actions>
      <div class="zaq-layout-stack">
        <form :if={length(@volume_options) > 1} id={"#{@id}-volume-form"} phx-change={@volume_event}>
          <.select
            id={"#{@id}-volume"}
            name="volume"
            label="Volume"
            value={@current_volume}
            options={@volume_options}
          />
        </form>

        <p
          :if={@destination}
          class="zaq-text-caption"
          style="color: var(--zaq-text-color-body-tertiary)"
        >
          Uploads to <span class="zaq-text-code">{@destination}</span>
        </p>

        <p
          :if={@description}
          class="zaq-text-body-sm"
          style="color: var(--zaq-text-color-body-tertiary)"
        >
          {@description}
        </p>

        <.upload_section
          uploads={@uploads}
          embedding_ready={@embedding_ready}
          folder_drop_skipped={@folder_drop_skipped}
          upload_name={@upload_name}
          id_prefix={@id_prefix}
          submit_event={@submit_event}
          change_event={@change_event}
          cancel_event={@file_cancel_event}
          label={@label}
          submit_label={@submit_label}
          hint={@hint || default_hint()}
          input_accept={@input_accept}
          too_large_message={@too_large_message}
          folder_drop?={@folder_drop?}
          show_submit?={false}
        >
          <:form_fields>{render_slot(@form_fields)}</:form_fields>
        </.upload_section>

        <div :if={@error} class="px-3 py-2 rounded-xl bg-red-50 border border-red-100">
          <p class="font-mono text-[0.72rem] text-red-500">{@error}</p>
        </div>
      </div>
    </.form_dialog>
    """
  end

  @doc """
  Dead-end notice shown when uploading needs a volume and none is connected.

  Built on `BOModal.modal_shell/1` rather than `confirm_dialog/1`: there is nothing to
  confirm and no destructive action to accept — the operator can only acknowledge and go
  connect a volume. It reuses the centered confirm layout classes with the warning badge
  modifier, so it reads as "blocked", not "about to delete something".
  """
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

  # `Map.keys/1` ordering is not guaranteed, so sort for a stable picker across renders.
  defp volume_options(volumes) when is_map(volumes) do
    volumes |> Map.keys() |> Enum.sort() |> Enum.map(&{&1, &1})
  end
end

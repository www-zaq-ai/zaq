defmodule ZaqWeb.Components.DesignSystem.ModalUpload do
  @moduledoc """
  BO upload modal — wraps `Dropzone.upload_section/1` in `BOModal.form_dialog/1`.

  Built for the ingestion page and still defaulting to its ids, events and copy, so
  `IngestionLive` renders identically without passing anything beyond `uploads`. Every
  other surface configures it:

    * **volume picker** — `volumes`; renders only when more than one is configured, so a
      single-volume deployment never sees a control with one option
    * **destination preview** — `destination`; renders only when given
    * **dropzone wiring** — `upload_name`, `id_prefix`, the three event names, the two
      labels, `hint` and `folder_drop?` are forwarded straight through, because two
      dropzones in one DOM must not share element ids

  Each is off or ingestion-shaped by default. Configure it; do not fork it — the skills
  page needs the same dialog with a volume picker and flat (no folder-drop) uploads, not a
  second modal.
  """

  use Phoenix.Component

  import ZaqWeb.Components.BOModal
  import ZaqWeb.Components.DesignSystem.Dropzone, only: [upload_section: 1, default_hint: 0]
  import ZaqWeb.CoreComponents, only: [icon: 1]
  import ZaqWeb.Select, only: [select: 1]

  attr :uploads, :any, required: true
  attr :id, :string, default: "upload-modal"
  attr :title, :string, default: "Upload data"
  attr :cancel_event, :string, default: "close_modal"

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
  attr :folder_drop?, :boolean, default: true

  def modal_upload(assigns) do
    assigns = assign(assigns, :volume_options, volume_options(assigns.volumes))

    ~H"""
    <.form_dialog
      id={@id}
      cancel_event={@cancel_event}
      title={@title}
      max_width_class="zaq-modal--width-xl"
    >
      <div class="zaq-layout-stack">
        <form :if={length(@volume_options) > 1} phx-change={@volume_event}>
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
          folder_drop?={@folder_drop?}
        />
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

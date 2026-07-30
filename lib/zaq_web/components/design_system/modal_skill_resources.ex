defmodule ZaqWeb.Components.DesignSystem.ModalSkillResources do
  @moduledoc """
  Upload modal for a skill's reference files — `BOModal.form_dialog/1` wrapping the shared
  `Dropzone.upload_section/1`.

  Mirrors `DesignSystem.ModalUpload` (the ingestion equivalent) and drives the same
  dropzone markup through its optional attrs, so the two upload surfaces cannot drift.
  Adds two things ingestion does not need: a volume picker, rendered only when more than
  one volume is configured, and a preview of the destination path so the operator can see
  where the file will land in the ingestion browser before committing.

  `modal_no_volume/1` lives here too: it is the same surface in its blocked state — what
  the operator gets instead of the upload modal when no volume is connected — and has no
  caller outside skill resources.
  """

  use Phoenix.Component

  import ZaqWeb.Components.BOModal
  import ZaqWeb.Components.DesignSystem.Dropzone, only: [upload_section: 1]
  import ZaqWeb.CoreComponents, only: [icon: 1]
  import ZaqWeb.Select, only: [select: 1]

  attr :uploads, :any, required: true

  attr :volumes, :map,
    required: true,
    doc: "`%{name => abs_path}` from `Ingestion.list_volumes/0`."

  attr :current_volume, :string, default: nil

  attr :destination, :string,
    required: true,
    doc: "Volume-relative path files will be written to."

  attr :hint, :string,
    required: true,
    doc: "Accepted extensions and size cap — the caller owns both numbers."

  attr :id, :string, default: "skill-resource-modal"
  attr :cancel_event, :string, default: "close_resource_modal"
  attr :volume_event, :string, default: "select_resource_volume"
  attr :title, :string, default: "Add resource"

  def modal_skill_resources(assigns) do
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

        <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary)">
          Uploads to <span class="zaq-text-code">{@destination}</span>
        </p>

        <.upload_section
          uploads={@uploads}
          upload_name={:skill_resources}
          id_prefix="skill-resource"
          submit_event="upload_skill_resource"
          change_event="validate_skill_resource"
          cancel_event="cancel_skill_resource"
          label="Reference file"
          hint={@hint}
          submit_label="Add"
          folder_drop?={false}
        />
      </div>
    </.form_dialog>
    """
  end

  @doc """
  Dead-end notice shown when adding a resource needs a volume and none is connected.

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

defmodule ZaqWeb.Components.DesignSystem.DataSourceFolderPicker do
  @moduledoc """
  Reusable BO folder picker for data-source backed destinations.
  """

  use ZaqWeb, :html

  alias ZaqWeb.Components.BOModal
  alias ZaqWeb.Components.DesignSystem.Button, as: DSButton
  alias ZaqWeb.Components.DesignSystem.IngestionSourceSelector

  attr :id, :string, default: "data-source-folder-picker"
  attr :sources, :list, default: []
  attr :source_id, :string, default: nil
  attr :entries, :list, default: []
  attr :stack, :list, default: []
  attr :error, :string, default: nil
  attr :title, :string, default: "Choose Folder"

  attr :description, :string,
    default: "Browse the selected data source, create folders, then select the current location."

  attr :close_event, :string, default: "close_modal"
  attr :new_folder_event, :string, default: "show_new_folder_modal"
  attr :navigate_event, :string, default: "folder_navigate"
  attr :up_event, :string, default: "folder_up"
  attr :select_event, :string, default: "confirm_folder"

  def folder_picker(assigns) do
    assigns = assign(assigns, :current_path, current_path(assigns.stack))

    ~H"""
    <BOModal.form_dialog
      id={@id}
      title={@title}
      cancel_event={@close_event}
      max_width_class="zaq-modal--width-3xl"
    >
      <div class="space-y-4">
        <p class="font-mono text-[0.72rem] text-black/40">{@description}</p>

        <IngestionSourceSelector.source_selector
          :if={@source_id && length(@sources) > 1}
          active_source_id={@source_id}
          sources={@sources}
        />

        <div :if={@error} class="px-3 py-2 rounded-xl bg-red-50 border border-red-100">
          <p class="font-mono text-[0.72rem] text-red-500">{@error}</p>
        </div>

        <div class="flex items-center justify-between gap-3">
          <div class="flex items-center gap-2 font-mono text-[0.72rem] min-w-0">
            <DSButton.button
              :if={@stack != []}
              type="button"
              variant={:ghost}
              icon="hero-chevron-left"
              icon_only
              aria-label="Go up"
              phx-click={@up_event}
            />
            <span class="text-black/35 shrink-0">Current:</span>
            <span class="font-semibold text-black truncate">{@current_path}</span>
          </div>

          <DSButton.button
            type="button"
            variant={:secondary}
            icon="hero-folder-plus"
            phx-click={@new_folder_event}
          >
            New folder
          </DSButton.button>
        </div>

        <div class="rounded-xl bg-[#fafafa] border border-black/[0.06] max-h-80 overflow-y-auto">
          <div :if={@entries == []} class="px-4 py-8 text-center">
            <p class="font-mono text-[0.75rem] text-black/30">No subfolders</p>
          </div>
          <button
            :for={folder <- @entries}
            type="button"
            phx-click={@navigate_event}
            phx-value-id={folder.id}
            class="w-full flex items-center gap-2.5 px-4 py-2.5 text-left transition-colors border-b border-black/[0.04] last:border-0 hover:bg-black/[0.02]"
          >
            <.icon name="hero-folder" class="zaq-icon-sm text-amber-400 shrink-0" />
            <span class="font-mono text-[0.8rem] text-black truncate">{folder.name}</span>
            <.icon name="hero-chevron-right" class="zaq-icon-sm text-black/20 ml-auto shrink-0" />
          </button>
        </div>
      </div>

      <:actions>
        <DSButton.button type="button" variant={:ghost} phx-click={@close_event}>
          Cancel
        </DSButton.button>
        <DSButton.button type="button" variant={:primary} phx-click={@select_event}>
          Select This Folder
        </DSButton.button>
      </:actions>
    </BOModal.form_dialog>
    """
  end

  defp current_path([]), do: "root"
  defp current_path(stack), do: Enum.map_join(stack, " / ", & &1.name)
end

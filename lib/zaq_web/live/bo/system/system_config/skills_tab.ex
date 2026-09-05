defmodule ZaqWeb.Live.BO.System.SystemConfig.SkillsTab do
  @moduledoc "Renders system settings for Agent Skills resource storage."

  use ZaqWeb, :html

  alias ZaqWeb.Components.DesignSystem.Button, as: DSButton
  alias ZaqWeb.Components.DesignSystem.DataSourceFolderPicker
  alias ZaqWeb.Components.DesignSystem.Input, as: DSInput
  alias ZaqWeb.Components.DesignSystem.ModalNewFolder

  attr :config, :map, required: true
  attr :sources, :list, default: []
  attr :source_id, :string, default: nil
  attr :folder_modal, :boolean, default: false
  attr :new_folder_modal, :boolean, default: false
  attr :folder_entries, :list, default: []
  attr :folder_stack, :list, default: []
  attr :folder_error, :string, default: nil
  attr :modal_error, :string, default: nil
  attr :modal_name, :string, default: ""

  def panel(assigns) do
    assigns =
      assigns
      |> assign(:folder_label, folder_label(assigns.config))
      |> assign(:can_choose_folder?, assigns.sources != [])

    ~H"""
    <div class="space-y-6">
      <div>
        <h2 class="font-mono text-lg font-semibold text-black">Agent Skills Resources</h2>
        <p class="font-mono text-[0.78rem] text-black/50 mt-1">
          Choose where newly created skill resource files are stored. Existing skills keep their
          pinned resource location and are not moved when this setting changes.
        </p>
      </div>

      <form
        id="skill-resource-config-form"
        phx-submit="save_skill_resource_config"
        class="space-y-4 max-w-2xl"
      >
        <DSInput.input type="hidden" name="skill_resources[provider]" value={@config.provider} />
        <DSInput.input type="hidden" name="skill_resources[config_id]" value={@config.config_id} />
        <DSInput.input type="hidden" name="skill_resources[scope_id]" value={@config.scope_id} />
        <DSInput.input type="hidden" name="skill_resources[folder_id]" value={@config.folder_id} />
        <DSInput.input type="hidden" name="skill_resources[folder_path]" value={@config.folder_path} />

        <div class="zaq-field-row-block">
          <span class="zaq-field-label-uppercase zaq-text-caption">Folder</span>
          <div class="rounded-xl border border-black/[0.08] bg-white px-4 py-3 flex items-center justify-between gap-4">
            <div class="min-w-0">
              <p class="font-mono text-[0.8rem] text-black truncate">{@folder_label}</p>
              <p class="font-mono text-[0.7rem] text-black/40 mt-1">
                Open the data-source browser to choose or create the destination folder.
              </p>
            </div>
            <DSButton.button
              type="button"
              variant={:secondary}
              phx-click="open_skill_resource_folder_modal"
              disabled={!@can_choose_folder?}
            >
              {if @config.folder_id, do: "Change", else: "Choose folder"}
            </DSButton.button>
          </div>
        </div>

        <div class="rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 font-mono text-[0.75rem] text-amber-900">
          Changing this default affects only skills that have not stored resources yet. ZAQ never
          relocates existing skill resource files automatically.
        </div>

        <DSButton.button type="submit" variant={:primary}>
          Save Skills Resource Settings
        </DSButton.button>
      </form>

      <DataSourceFolderPicker.folder_picker
        :if={@folder_modal}
        id="skill-resource-folder-picker"
        title="Choose Skills Folder"
        sources={@sources}
        source_id={@source_id}
        entries={@folder_entries}
        stack={@folder_stack}
        error={@folder_error}
        close_event="close_modal"
        navigate_event="skill_resource_folder_navigate"
        up_event="skill_resource_folder_up"
        select_event="confirm_skill_resource_folder"
      />

      <ModalNewFolder.modal_new_folder
        :if={@new_folder_modal}
        modal_error={@modal_error}
        modal_name={@modal_name}
      />
    </div>
    """
  end

  defp folder_label(%{folder_path: path}) when is_binary(path) and path != "", do: path
  defp folder_label(%{folder_id: id}) when not is_nil(id), do: "root"
  defp folder_label(_), do: "No folder selected"
end

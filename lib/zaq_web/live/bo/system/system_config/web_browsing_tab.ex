defmodule ZaqWeb.Live.BO.System.SystemConfig.WebBrowsingTab do
  @moduledoc "Renders the administrator-owned browser policy and screenshot destination."

  use ZaqWeb, :html

  alias ZaqWeb.Components.DesignSystem.{Button, DataSourceFolderPicker, Input, ModalNewFolder}
  alias ZaqWeb.Live.BO.DataSourceBrowser

  attr :config, :map, required: true
  attr :load_error, :string, default: nil
  attr :sources, :list, default: []
  attr :folder_entries, :list, default: []
  attr :source_id, :string, default: nil
  attr :folder_error, :string, default: nil
  attr :folder_modal, :boolean, default: false
  attr :modal_name, :string, default: ""
  attr :new_folder_modal, :boolean, default: false
  attr :folder_stack, :list, default: []
  attr :modal_error, :string, default: nil

  def panel(assigns) do
    assigns = assign(assigns, :folder_label, DataSourceBrowser.folder_label(assigns.config))

    ~H"""
    <section class="zaq-card-default p-8 zaq-layout-stack zaq-layout-stack--lg">
      <div class="zaq-layout-stack zaq-layout-stack--xs">
        <h2 class="zaq-text-heading-sm">Web browsing</h2>
        <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
          Control which sites the agent may browse and where its screenshots are saved.
        </p>
      </div>

      <div :if={@load_error} role="alert" class="zaq-card-subtle p-5">
        Could not load Web browsing settings. Browsing policy cannot be changed until this is resolved.
      </div>

      <form
        :if={!@load_error}
        id="web-browsing-config-form"
        phx-submit="save_web_browsing_config"
        class="zaq-layout-stack zaq-layout-stack--lg max-w-2xl"
      >
        <Input.input
          id="web-browsing-allowed-domains"
          name="web_browsing[allowed_domains]"
          label="Allowed domains"
          value={@config.allowed_domains}
          placeholder="zaq.ai, www.zaq.ai"
        />
        <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
          Comma-separated exact hostnames. Leave blank to allow any domain. Include hosts used by redirects and required page resources.
        </p>
        <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-warning)">
          Restart every Agent container after changing allowed domains. This closes ephemeral browser sessions; saving does not update running browsers.
        </p>

        <Input.input type="hidden" name="web_browsing[provider]" value={@config.provider} />
        <Input.input type="hidden" name="web_browsing[config_id]" value={@config.config_id} />
        <Input.input type="hidden" name="web_browsing[scope_id]" value={@config.scope_id} />
        <Input.input type="hidden" name="web_browsing[folder_id]" value={@config.folder_id} />
        <Input.input type="hidden" name="web_browsing[folder_path]" value={@config.folder_path} />

        <div class="zaq-field-row-block">
          <span class="zaq-field-label-uppercase zaq-text-caption">Screenshot destination</span>
          <div class="rounded-xl border border-black/[0.08] bg-white px-4 py-3 flex items-center justify-between gap-4">
            <div class="min-w-0">
              <p id="web-browsing-selected-folder" class="font-mono text-[0.8rem] text-black truncate">
                {@folder_label}
              </p>
              <p class="font-mono text-[0.7rem] text-black/40 mt-1">
                {if @config.provider,
                  do: "Open the data-source browser to choose or create the destination folder.",
                  else: "Browsing works, but screenshots cannot be stored without a destination."}
              </p>
            </div>
            <Button.button
              type="button"
              variant={:secondary}
              phx-click="open_web_browsing_folder_modal"
              disabled={@sources == []}
            >
              {if @config.folder_id || @config.folder_path, do: "Change", else: "Choose folder"}
            </Button.button>
          </div>
          <Button.button
            :if={@config.provider}
            type="button"
            variant={:secondary}
            phx-click="clear_web_browsing_folder"
          >
            Clear destination
          </Button.button>
        </div>

        <Button.button type="submit" variant={:primary}>Save Web browsing settings</Button.button>
      </form>

      <DataSourceFolderPicker.folder_picker
        :if={@folder_modal}
        id="web-browsing-folder-picker"
        title="Choose Screenshot Folder"
        sources={@sources}
        source_id={@source_id}
        entries={@folder_entries}
        stack={@folder_stack}
        error={@folder_error}
        close_event="close_modal"
        navigate_event="web_browsing_folder_navigate"
        up_event="web_browsing_folder_up"
        select_event="confirm_web_browsing_folder"
      />

      <ModalNewFolder.modal_new_folder
        :if={@new_folder_modal}
        modal_error={@modal_error}
        modal_name={@modal_name}
      />
    </section>
    """
  end
end

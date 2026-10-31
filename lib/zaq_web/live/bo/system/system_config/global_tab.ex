defmodule ZaqWeb.Live.BO.System.SystemConfig.GlobalTab do
  @moduledoc """
  Tab component for the BO system configuration page.
  """
  use ZaqWeb, :html
  alias ZaqWeb.Components.DesignSystem.{Button, CardShell, Input}

  attr :global_agent_options, :list, required: true
  attr :global_default_agent_id, :any, required: true
  attr :global_base_url, :string, required: true
  attr :global_language, :string, required: true
  attr :global_timezone, :any, required: true
  attr :detected_timezone, :any, default: nil

  @gmt_offsets for h <- -12..14,
                   do:
                     "GMT#{if h >= 0, do: "+", else: ""}#{String.pad_leading(to_string(h), 2, "0")}:00"

  def panel(assigns) do
    assigns = assign(assigns, :gmt_offsets, @gmt_offsets)

    ~H"""
    <CardShell.card_shell id="global-settings-section">
      <div class="zaq-layout-stack">
        <header>
          <h2 class="zaq-text-h3" style="color: var(--zaq-text-color-body-default)">Global</h2>
          <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-secondary)">
            Configure system-wide defaults used across OAuth2, webhooks, and channel-level routing.
          </p>
        </header>
        <div class="space-y-6">
          <div>
            <label for="global-base-url-input" class="zaq-field-label-uppercase block mb-2">
              Global Base URL
            </label>
            <form
              phx-submit="save_global_base_url"
              class="flex flex-col sm:flex-row sm:items-center gap-2"
            >
              <div class="w-full max-w-md min-w-0">
                <Input.input
                  id="global-base-url-input"
                  name="global_base_url"
                  type="text"
                  value={@global_base_url}
                  placeholder="https://zaq.example"
                />
              </div>
              <Button.button type="submit" variant={:secondary}>
                Save
              </Button.button>
            </form>
            <p class="zaq-text-caption mt-2" style="color: var(--zaq-text-color-body-secondary)">
              Project-wide base URL used by OAuth2 redirects, webhooks, and future global callbacks.
            </p>
          </div>

          <div>
            <label for="global-default-agent-select" class="zaq-field-label-uppercase block mb-2">
              Global Default Agent
            </label>
            <form
              phx-submit="save_global_default_agent"
              class="flex flex-col sm:flex-row sm:items-center gap-2"
            >
              <select
                id="global-default-agent-select"
                name="global_default_agent_id"
                class="w-full max-w-md zaq-control-select"
              >
                <option value="" selected={is_nil(@global_default_agent_id)}>
                  Default Zaq Agent
                </option>
                <option
                  :for={{name, id} <- @global_agent_options}
                  value={id}
                  selected={to_string(@global_default_agent_id || "") == to_string(id)}
                >
                  {name}
                </option>
              </select>
              <Button.button type="submit" variant={:secondary}>
                Save
              </Button.button>
            </form>
          </div>

          <div>
            <label for="global-language-select" class="zaq-field-label-uppercase block mb-2">
              Language
            </label>
            <form
              phx-submit="save_global_language"
              class="flex flex-col sm:flex-row sm:items-center gap-2"
            >
              <select
                id="global-language-select"
                name="language"
                class="w-full max-w-md zaq-control-select"
              >
                <option value="en" selected={@global_language == "en"}>English</option>
                <option value="fr" disabled selected={@global_language == "fr"}>French</option>
              </select>
              <Button.button type="submit" variant={:secondary}>
                Save
              </Button.button>
            </form>
            <p class="zaq-text-caption mt-2" style="color: var(--zaq-text-color-body-secondary)">
              System language for UI labels and notifications. French is not yet implemented.
            </p>
          </div>

          <div id="global-timezone-section" phx-hook="DetectTimezone">
            <label for="global-timezone-select" class="zaq-field-label-uppercase block mb-2">
              TimeZone
            </label>
            <form
              phx-submit="save_global_timezone"
              class="flex flex-col sm:flex-row sm:items-center gap-2"
            >
              <select
                id="global-timezone-select"
                name="timezone"
                class="w-full max-w-md zaq-control-select"
              >
                <option value="">—</option>
                <option
                  :for={gmt <- @gmt_offsets}
                  value={gmt}
                  selected={
                    (@global_timezone && @global_timezone == gmt) ||
                      (is_nil(@global_timezone) && @detected_timezone == gmt)
                  }
                >
                  {gmt}
                </option>
              </select>
              <Button.button type="submit" variant={:secondary}>
                Save
              </Button.button>
            </form>
            <p
              :if={@detected_timezone && is_nil(@global_timezone)}
              class="zaq-text-caption mt-2"
              style="color: var(--zaq-text-color-body-accent)"
            >
              Detected: {@detected_timezone}
            </p>
            <p
              :if={@global_timezone}
              class="zaq-text-caption mt-2"
              style="color: var(--zaq-text-color-body-secondary)"
            >
              Display timezone for message timestamps and workflow run times.
            </p>
          </div>
        </div>
      </div>
    </CardShell.card_shell>
    """
  end
end

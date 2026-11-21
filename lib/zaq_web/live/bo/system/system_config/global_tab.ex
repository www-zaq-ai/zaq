defmodule ZaqWeb.Live.BO.System.SystemConfig.GlobalTab do
  @moduledoc """
  Tab component for the BO system configuration page.
  """
  use ZaqWeb, :html
  alias Zaq.System.GrpcConfig
  alias ZaqWeb.Components.DesignSystem.{Button, CardShell, Input}
  alias ZaqWeb.Select

  attr :global_agent_options, :list, required: true
  attr :global_default_agent_id, :any, required: true
  attr :global_base_url, :string, required: true
  attr :global_language, :string, required: true
  attr :global_timezone, :any, required: true
  attr :detected_timezone, :any, default: nil
  attr :grpc_limit_form, Phoenix.HTML.Form, default: nil
  attr :grpc_limit_error, :string, default: nil

  @gmt_offsets for h <- -12..14,
                   do:
                     "GMT#{if h >= 0, do: "+", else: ""}#{String.pad_leading(to_string(h), 2, "0")}:00"

  def panel(assigns) do
    assigns = assign(assigns, :gmt_offsets, @gmt_offsets)

    assigns =
      assign(
        assigns,
        :grpc_limit_form,
        assigns.grpc_limit_form ||
          to_form(%{
            "grpc_max_message_mib" => div(GrpcConfig.default_max_message_bytes(), 1_048_576)
          })
      )

    ~H"""
    <CardShell.card_shell id="global-settings-section">
      <div class="zaq-layout-stack">
        <header>
          <h2 class="zaq-text-h3" style="color: var(--zaq-text-color-body-default)">Global</h2>
          <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-secondary)">
            Configure system-wide defaults for OAuth2, webhooks, channel-level routing, and transport limits.
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
            <label
              for="global-default-agent-select-trigger"
              class="zaq-field-label-uppercase block mb-2"
            >
              Global Default Agent
            </label>
            <form
              phx-submit="save_global_default_agent"
              class="flex flex-col sm:flex-row sm:items-center gap-2"
            >
              <Select.select
                id="global-default-agent-select"
                name="global_default_agent_id"
                class="w-full max-w-md min-w-0"
                value={@global_default_agent_id || ""}
                options={[{"Unconfigured", ""}, {"None", "none"} | @global_agent_options]}
              />
              <Button.button type="submit" variant={:secondary}>
                Save
              </Button.button>
            </form>
          </div>

          <div>
            <label for="global-language-select-trigger" class="zaq-field-label-uppercase block mb-2">
              Language
            </label>
            <form
              phx-submit="save_global_language"
              class="flex flex-col sm:flex-row sm:items-center gap-2"
            >
              <Select.select
                id="global-language-select"
                name="language"
                class="w-full max-w-md min-w-0"
                value={@global_language}
                options={[{"English", "en"}, {"French", "fr", nil, true}]}
              />
              <Button.button type="submit" variant={:secondary}>
                Save
              </Button.button>
            </form>
            <p class="zaq-text-caption mt-2" style="color: var(--zaq-text-color-body-secondary)">
              System language for UI labels and notifications. French is not yet implemented.
            </p>
          </div>

          <div>
            <label for="global-grpc-limit-input" class="zaq-field-label-uppercase block mb-2">
              gRPC maximum message size (MiB)
            </label>
            <.form
              for={@grpc_limit_form}
              id="global-grpc-limit-form"
              phx-submit="save_grpc_max_message_mib"
              class="zaq-layout-inline"
            >
              <div class="w-full max-w-md min-w-0">
                <Input.input
                  field={@grpc_limit_form[:grpc_max_message_mib]}
                  id="global-grpc-limit-input"
                  type="number"
                  min="1"
                  max={GrpcConfig.max_message_mib()}
                  step="1"
                  required
                  aria-describedby={
                    if @grpc_limit_error,
                      do: "global-grpc-limit-hint global-grpc-limit-error",
                      else: "global-grpc-limit-hint"
                  }
                />
              </div>
              <Button.button type="submit" variant={:secondary}>Save</Button.button>
            </.form>
            <p
              :if={@grpc_limit_error}
              id="global-grpc-limit-error"
              role="alert"
              class="zaq-text-caption mt-2"
              style="color: var(--zaq-text-color-danger)"
            >
              {@grpc_limit_error}
            </p>
            <p
              id="global-grpc-limit-hint"
              class="zaq-text-caption mt-2"
              style="color: var(--zaq-text-color-body-secondary)"
            >
              Maximum encoded gRPC message size for sending and receiving. Default: 64 MiB.
              Engine restart required on each node. Gateway negotiation may lower this limit.
            </p>
          </div>

          <div id="global-timezone-section" phx-hook="DetectTimezone">
            <label for="global-timezone-select-trigger" class="zaq-field-label-uppercase block mb-2">
              TimeZone
            </label>
            <form
              phx-submit="save_global_timezone"
              class="flex flex-col sm:flex-row sm:items-center gap-2"
            >
              <Select.select
                id="global-timezone-select"
                name="timezone"
                class="w-full max-w-md min-w-0"
                value={@global_timezone || @detected_timezone || ""}
                options={[{"—", ""} | Enum.map(@gmt_offsets, &{&1, &1})]}
              />
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

defmodule ZaqWeb.Live.BO.System.SystemConfig.PeopleAccessTab do
  @moduledoc "People access configuration panel for SystemConfigLive; presentation only."
  use ZaqWeb, :html

  alias ZaqWeb.Components.DesignSystem.Button
  alias ZaqWeb.Components.DesignSystem.Input

  attr :form, :any, required: true
  attr :load_error, :string, default: nil

  def panel(assigns) do
    ~H"""
    <section
      id="people-access-panel"
      class="zaq-card-default zaq-layout-content-inset zaq-layout-stack"
    >
      <h2 class="zaq-text-h2">People access</h2>
      <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
        Configure access durations and attempt limits. These settings are stored for future
        People access flows; authentication and rate limiting do not consume them yet.
      </p>
      <div :if={@load_error} class="zaq-layout-stack" role="alert">
        <p class="zaq-text-body" style="color: var(--zaq-text-color-body-danger)">{@load_error}</p>
        <Button.button
          id="people-access-retry"
          variant={:secondary}
          phx-click="retry_people_access_config"
        >
          Retry
        </Button.button>
        <Button.button id="people-access-save" disabled>Save People access settings</Button.button>
      </div>
      <.form
        :if={@form}
        id="people-access-config-form"
        for={@form}
        phx-change="validate_people_access_config"
        phx-submit="save_people_access_config"
        class="zaq-layout-stack"
      >
        <p
          :for={error <- Keyword.get_values(@form.errors, :base)}
          class="zaq-field-error zaq-text-body-sm"
        >
          {translate_error(error)}
        </p>
        <fieldset class="zaq-layout-stack">
          <legend class="zaq-text-h3">OTP</legend>
          <p class="zaq-text-body-sm">Codes have a fixed length of eight digits.</p>
          <Input.input
            field={@form[:otp_validity_seconds]}
            type="number"
            min="1"
            step="1"
            required
            label="OTP validity (seconds)"
            aria-describedby="otp-validity-hint"
          />
          <p id="otp-validity-hint" class="zaq-text-body-sm">Default: 5 minutes.</p>
          <Input.input
            field={@form[:otp_max_attempts]}
            type="number"
            min="1"
            step="1"
            required
            label="Maximum verification attempts per OTP"
          />
        </fieldset>
        <fieldset class="zaq-layout-stack">
          <legend class="zaq-text-h3">Unknown email protection</legend>
          <Input.input
            field={@form[:unknown_email_attempt_limit]}
            type="number"
            min="1"
            step="1"
            required
            label="Unknown email attempt limit"
          />
          <Input.input
            field={@form[:unknown_email_window_seconds]}
            type="number"
            min="1"
            step="1"
            required
            label="Unknown email window (seconds)"
            aria-describedby="unknown-email-window-hint"
          />
          <p id="unknown-email-window-hint" class="zaq-text-body-sm">Default: 10 minutes.</p>
          <Input.input
            field={@form[:unknown_email_cooldown_seconds]}
            type="number"
            min="1"
            step="1"
            required
            label="Unknown email cooldown (seconds)"
            aria-describedby="unknown-email-cooldown-hint"
          />
          <p id="unknown-email-cooldown-hint" class="zaq-text-body-sm">Default: 15 minutes.</p>
        </fieldset>
        <fieldset class="zaq-layout-stack">
          <legend class="zaq-text-h3">OTP sends</legend>
          <Input.input
            field={@form[:otp_send_person_limit]}
            type="number"
            min="1"
            step="1"
            required
            label="OTP send limit per person"
          />
          <Input.input
            field={@form[:otp_send_ip_limit]}
            type="number"
            min="1"
            step="1"
            required
            label="OTP send limit per IP"
          />
          <Input.input
            field={@form[:otp_send_window_seconds]}
            type="number"
            min="1"
            step="1"
            required
            label="OTP send window (seconds)"
            aria-describedby="otp-send-window-hint"
          />
          <p id="otp-send-window-hint" class="zaq-text-body-sm">Default: 15 minutes.</p>
        </fieldset>
        <fieldset class="zaq-layout-stack">
          <legend class="zaq-text-h3">Sessions</legend>
          <Input.input
            field={@form[:session_lifetime_seconds]}
            type="number"
            min="1"
            step="1"
            required
            label="Session lifetime (seconds)"
            aria-describedby="session-lifetime-hint"
          />
          <p id="session-lifetime-hint" class="zaq-text-body-sm">Default: 7 days.</p>
        </fieldset>
        <Button.button id="people-access-save" type="submit" phx-disable-with="Saving…">
          Save People access settings
        </Button.button>
      </.form>
    </section>
    """
  end
end

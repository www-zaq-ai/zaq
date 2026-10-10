defmodule ZaqWeb.Components.DesignSystem.DeviceSignIn do
  @moduledoc "Shared device-code instructions and terminal statuses for BO and People modals."
  use Phoenix.Component
  alias ZaqWeb.Components.DesignSystem.Button

  @doc "Whether sign-in is starting or awaiting approval, so modal actions must not start it again."
  def in_progress?(%{status: status}), do: status in ["initializing", "pending"]
  def in_progress?(_), do: false

  attr :id, :string, required: true
  attr :attempt, :map, required: true

  def device_sign_in(assigns) do
    ~H"""
    <section id={@id} class="zaq-layout-stack" aria-live="polite">
      <%= if @attempt.status == "pending" do %>
        <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
          Open the provider's sign-in page and enter this code. Only continue if you started this sign-in in ZAQ.
        </p>
        <div class="flex items-center gap-3">
          <span
            class="zaq-text-body-sm min-w-0 flex-1 break-all"
            style="color: var(--zaq-text-color-body-secondary)"
          >
            {@attempt.verification_uri}
          </span>
          <Button.button
            id={@id <> "-open"}
            href={@attempt.verification_uri}
            target="_blank"
            rel="noopener noreferrer"
            variant={:secondary}
            class="shrink-0"
            icon="hero-arrow-top-right-on-square"
          >Open in new tab</Button.button>
        </div>
        <div>
          <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary)">
            Sign-in code
          </p>
          <strong
            id={@id <> "-code"}
            class="zaq-text-body-lg"
            style="color: var(--zaq-text-color-body-default)"
          >
            {@attempt.user_code}
          </strong>
        </div>
        <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary)">
          Waiting for approval. Expires at {Calendar.strftime(@attempt.expires_at, "%H:%M UTC")}.
          You can leave this page while sign-in continues.
        </p>
      <% else %>
        <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
          {status_message(@attempt.status)}
        </p>
      <% end %>
    </section>
    """
  end

  defp status_message("active"), do: "Device sign-in completed. Your credential is connected."

  defp status_message("initializing"),
    do: "Starting sign-in. Please wait; you can cancel this sign-in."

  defp status_message("interrupted"),
    do: "Sign-in was interrupted. Start a new device sign-in; the previous flow cannot resume."

  defp status_message("expired"), do: "The sign-in code expired. Start a new device sign-in."

  defp status_message("denied"),
    do: "Authorization was denied. Start a new device sign-in to try again."

  defp status_message("cancelled"), do: "Device sign-in cancelled."
  defp status_message("unavailable"), do: "This sign-in is no longer available. Start again."
  defp status_message(_), do: "Device sign-in failed. Start a new device sign-in to try again."
end

defmodule ZaqWeb.Components.DesignSystem.FeedbackBanner do
  @moduledoc """
  Inline success and error feedback for application actions.

  The banner supports LiveView flash dismissal and optional automatic dismissal.
  """

  use Phoenix.Component

  attr :kind, :atom, required: true, values: [:info, :error]
  attr :message, :string, required: true
  attr :id, :string, default: nil
  attr :auto_dismiss, :boolean, default: true
  attr :auto_dismiss_duration, :integer, default: 5000

  def feedback_banner(assigns) do
    assigns = assign(assigns, :id, assigns.id || "flash-#{assigns.kind}")

    ~H"""
    <div
      id={@id}
      role={if @kind == :error, do: "alert", else: "status"}
      class={[
        "zaq-feedback-banner zaq-text-body",
        @kind == :error && "zaq-danger",
        @kind == :info && "zaq-success"
      ]}
      phx-hook="FlashAutoDismiss"
      data-auto-dismiss-duration={if @auto_dismiss, do: @auto_dismiss_duration, else: 0}
    >
      <span class="zaq-feedback-icon" aria-hidden="true">
        <svg
          :if={@kind == :info}
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          viewBox="0 0 24 24"
        >
          <path d="M5 13l4 4L19 7" />
        </svg>
        <svg
          :if={@kind == :error}
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          viewBox="0 0 24 24"
        >
          <circle cx="12" cy="12" r="10" /><path d="M12 8v4m0 4h.01" />
        </svg>
      </span>
      <span class="zaq-feedback-body">{flash_body(@message)}</span>
      <button
        type="button"
        phx-click="lv:clear-flash"
        phx-value-key={@kind}
        data-flash-dismiss
        class="zaq-feedback-dismiss"
        aria-label="Dismiss"
      >
        <svg aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
          <path d="M6 18L18 6M6 6l12 12" />
        </svg>
      </button>
    </div>
    """
  end

  # `Zaq.UserPortal.provision_error/1` deliberately includes this phrase. Escape the
  # complete message before adding the one trusted link so interpolated values remain safe.
  defp flash_body(message) do
    escaped = message |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    case String.split(escaped, "user portal", parts: 2) do
      [before, rest] ->
        href =
          Zaq.UserPortal.base_url() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

        Phoenix.HTML.raw(
          before <>
            ~s(<a href="#{href}" target="_blank" rel="noopener noreferrer" class="underline">user portal</a>) <>
            rest
        )

      _ ->
        Phoenix.HTML.raw(escaped)
    end
  end
end

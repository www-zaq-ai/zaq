defmodule ZaqWeb.Components.DesignSystem.DeviceSignIn do
  @moduledoc """
  Shared normalized sign-in challenges, account confirmation and terminal guidance.
  Callers retain modal shells and actions. QR values become local SVG modules,
  never provider markup or a browser-visible raw payload.
  """
  use Phoenix.Component
  alias ZaqWeb.Components.DesignSystem.Button

  @doc "Whether sign-in is starting or awaiting approval, so modal actions must not start it again."
  def in_progress?(%{status: status}), do: status in ["initializing", "pending"]
  def in_progress?(_), do: false

  attr :id, :string, required: true
  attr :attempt, :map, required: true
  attr :provider, :string, default: "the provider"
  slot :inner_block

  def device_sign_in(assigns) do
    challenge = if assigns.attempt.status == "pending", do: assigns.attempt[:challenge]

    assigns =
      assigns
      |> assign(:challenge, safe_challenge(challenge))
      |> assign(:matrix, qr_matrix(challenge))

    ~H"""
    <section id={@id} class="zaq-layout-stack" aria-live="polite">
      <%= if @challenge && @challenge.type == :verification_code do %>
        <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
          Open the provider's sign-in page and enter this code. Only continue if you started this sign-in in ZAQ.
        </p>
        <div class="flex items-center gap-3">
          <span
            class="zaq-text-body-sm min-w-0 flex-1 break-all"
            style="color: var(--zaq-text-color-body-secondary)"
          >
            {@challenge.uri}
          </span>
          <Button.button
            id={@id <> "-open"}
            href={@challenge.uri}
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
            {@challenge.code}
          </strong>
        </div>
        <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary)">
          Waiting for approval. Expires at {Calendar.strftime(@challenge.expires_at, "%H:%M UTC")}.
          You can leave this page while sign-in continues.
        </p>
      <% else %>
        <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
          {@attempt[:summary] || status_message(@attempt.status)}
        </p>
        <p :if={@matrix} class="zaq-text-body-sm">
          Open {@provider} on your device and scan this code.
        </p>
        <.qr :if={@matrix} matrix={@matrix} />
        <div
          :if={@attempt.status == "confirm" && is_map(@attempt[:confirmation])}
          class="zaq-layout-stack"
        >
          <p class="zaq-text-body">{@attempt.confirmation[:display_name] || "Connected account"}</p>
          <p class="zaq-text-body" id={@id <> "-account-id"}>{@attempt.confirmation[:external_id]}</p>
          <p class="zaq-text-body-sm">Confirm to create this channel and start receiving messages.</p>
        </div>
      <% end %>
      {render_slot(@inner_block)}
    </section>
    """
  end

  defp safe_challenge(
         %{type: :verification_code, uri: uri, code: code, expires_at: %DateTime{}} = challenge
       )
       when is_binary(uri) and is_binary(code) do
    case URI.parse(uri) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> challenge
      _ -> nil
    end
  end

  defp safe_challenge(_), do: nil

  defp qr_matrix(%{type: :qr, value: qr}) when is_binary(qr) and byte_size(qr) in 1..2048 do
    case QRCode.create(qr) do
      {:ok, %{matrix: matrix}} -> matrix
      _ -> nil
    end
  end

  defp qr_matrix(_), do: nil

  attr :matrix, :list, required: true

  defp qr(assigns) do
    runs =
      for {row, y} <- Enum.with_index(assigns.matrix),
          chunk <- row |> Enum.with_index() |> Enum.chunk_by(fn {v, _} -> v in [1, true] end),
          {value, x} = hd(chunk),
          value in [1, true],
          do: {x + 4, y + 4, length(chunk)}

    assigns = assigns |> assign(:size, length(assigns.matrix) + 8) |> assign(:runs, runs)

    ~H"""
    <svg
      class="zaq-linked-device-qr"
      viewBox={"0 0 #{@size} #{@size}"}
      shape-rendering="crispEdges"
      role="img"
      aria-label="Device connection QR code"
      xmlns="http://www.w3.org/2000/svg"
    >
      <rect class="zaq-linked-device-qr-background" width={@size} height={@size} />
      <rect
        :for={{x, y, width} <- @runs}
        class="zaq-linked-device-qr-module"
        x={x}
        y={y}
        width={width}
        height="1"
      />
    </svg>
    """
  end

  defp status_message("active"), do: "Device sign-in completed. Your credential is connected."
  defp status_message("pending"), do: "Waiting for connection"
  defp status_message("confirm"), do: "Confirm the linked account."

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

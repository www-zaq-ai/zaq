defmodule ZaqWeb.Components.DesignSystem.LinkedDevicePairing do
  @moduledoc "Provider-neutral pairing presentation. Renders QR modules, never provider-supplied markup."
  use Phoenix.Component
  alias ZaqWeb.Components.BOModal
  alias ZaqWeb.Components.DesignSystem.Button

  attr :id, :string, default: "linked-device-pairing"
  attr :name, :string, required: true
  attr :provider, :string, required: true
  attr :status, :map, required: true
  attr :cancel_connection, :boolean, default: false
  attr :close_event, :string, default: "close_linked_device"
  attr :retry_event, :string, default: "retry_linked_device"
  attr :history_disabled, :boolean, default: false

  def modal(assigns) do
    cancel? = assigns.cancel_connection and assigns.status[:phase] != :connected

    assigns =
      assigns
      |> assign(:matrix, qr_matrix(assigns.status))
      |> assign(
        :dismiss_event,
        if(cancel?, do: "cancel_linked_device_connection", else: assigns.close_event)
      )
      |> assign(:dismiss_label, if(cancel?, do: "Cancel connection", else: "Close"))

    ~H"""
    <BOModal.form_dialog
      id={@id}
      title={"Connect #{@provider}"}
      cancel_event={@dismiss_event}
      max_width_class="zaq-modal--width-md"
    >
      <div class="zaq-layout-stack">
        <p class="zaq-text-body">{@name}</p>
        <p class="zaq-text-body-sm" role="status">{@status[:summary] || "Waiting for connection"}</p>
        <p :if={@matrix} class="zaq-text-body-sm">
          Open {@provider} on your device and scan this code.
        </p>
        <.qr :if={@matrix} matrix={@matrix} />
        <div :if={@status[:phase] == :confirm} class="zaq-layout-stack">
          <p class="zaq-text-body">{@status.account[:display_name] || "Connected account"}</p>
          <p class="zaq-text-body" id="linked-device-account-id">{@status.account.external_id}</p>
          <p class="zaq-text-body-sm">Confirm to create this channel and start receiving messages.</p>
        </div>
        <p :if={@history_disabled} class="zaq-text-body-sm">
          History sync is disabled. Messages queued while ZAQ is offline follow your normal routing rules.
        </p>
      </div>
      <:actions>
        <Button.button variant={:secondary} phx-click={@dismiss_event}>{@dismiss_label}</Button.button>
        <Button.button
          :if={@status[:phase] == :confirm}
          phx-click="confirm_linked_device"
          phx-disable-with="Saving…"
        >
          Confirm account
        </Button.button>
        <Button.button
          :if={@status[:phase] in [:expired, :disconnected, :failed]}
          phx-click={@retry_event}
        >
          Retry connection
        </Button.button>
      </:actions>
    </BOModal.form_dialog>
    """
  end

  defp qr_matrix(%{phase: :pairing, qr: qr}) when is_binary(qr) and byte_size(qr) in 1..2048 do
    case QRCode.create(qr) do
      {:ok, %{matrix: matrix}} -> matrix
      _ -> nil
    end
  end

  defp qr_matrix(_), do: nil

  attr :matrix, :list, required: true

  defp qr(assigns) do
    size = length(assigns.matrix) + 8

    runs =
      for {row, y} <- Enum.with_index(assigns.matrix),
          chunk <- row |> Enum.with_index() |> Enum.chunk_by(fn {v, _} -> v in [1, true] end),
          {value, x} = hd(chunk),
          value in [1, true],
          do: {x + 4, y + 4, length(chunk)}

    assigns = assigns |> assign(:size, size) |> assign(:runs, runs)

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
end

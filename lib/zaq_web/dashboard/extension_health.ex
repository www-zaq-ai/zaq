defmodule ZaqWeb.Dashboard.ExtensionHealth do
  @moduledoc "Gateway connectivity row for the existing dashboard add-on card."

  use Phoenix.Component

  attr :id, :string, default: "dashboard-extension-health"
  attr :health, :map, required: true

  def extension_health(assigns) do
    ~H"""
    <div
      id={@id}
      data-status={@health.status}
      class="w-full space-y-2"
      aria-live="polite"
    >
      <div class="flex flex-wrap items-center justify-between gap-2">
        <span class="zaq-text-body-sm">Extension gateway</span>
        <span class={["zaq-pill zaq-text-caption", tone(@health.status)]}>
          {label(@health.status)}
        </span>
      </div>
      <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary);">
        {message(@health.status)} Add-on access is unchanged.
      </p>
      <p
        :if={@health.checked_at}
        class="zaq-text-caption"
        style="color: var(--zaq-text-color-body-tertiary);"
      >
        Last checked:
        <time datetime={DateTime.to_iso8601(@health.checked_at)}>
          {Calendar.strftime(@health.checked_at, "%H:%M:%S UTC")}
        </time>
      </p>
    </div>
    """
  end

  defp label(:unconfigured), do: "Unconfigured"
  defp label(:checking), do: "Checking…"
  defp label(:healthy), do: "Healthy"
  defp label(:unreachable), do: "Unreachable"
  defp label(:error), do: "Error"

  defp tone(:healthy), do: "zaq-pill--success"
  defp tone(:checking), do: "zaq-pill--accent zaq-pill--pulse"
  defp tone(:error), do: "zaq-pill--danger"
  defp tone(_status), do: "zaq-pill--elevated"

  defp message(:unconfigured), do: "Optional connection is not configured."
  defp message(:checking), do: "Waiting for the first Health result."
  defp message(:healthy), do: "Health RPC returned ok."
  defp message(:unreachable), do: "Gateway or Engine unavailable; retrying."
  defp message(:error), do: "Check gateway configuration and certificates."
end

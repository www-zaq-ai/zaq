defmodule ZaqWeb.Live.BO.Communication.IngressStatusUI do
  @moduledoc false

  def color(status) do
    status
    |> status_value()
    |> status_color()
  end

  defp status_value(nil), do: nil
  defp status_value(status), do: status[:status] || status["status"]

  defp status_color(status) when status in [:ok, "ok"], do: "status-success"
  defp status_color(status) when status in [:error, "error"], do: "status-error"
  defp status_color(status) when status in [:pending, "pending"], do: "status-warning"
  defp status_color(_status), do: "status-neutral"

  def pending?(status) when is_map(status) do
    status_value(status) in [:pending, "pending"]
  end

  def pending?(_status), do: false

  def any_pending?(statuses) when is_map(statuses),
    do: Enum.any?(statuses, fn {_key, status} -> pending?(status) end)

  def any_pending?(_statuses), do: false

  def maybe_schedule_pending_refresh(socket, message, retry_ms, max_attempts) do
    attempts = socket.assigns[:ingress_status_refresh_attempts] || 0

    if any_pending?(socket.assigns.ingress_statuses) and attempts < max_attempts do
      Process.send_after(self(), message, retry_ms)
      Phoenix.Component.assign(socket, :ingress_status_refresh_attempts, attempts + 1)
    else
      socket
    end
  end

  def normalize_response({:ok, status}) when is_map(status), do: status

  def normalize_response({:error, reason}) do
    %{status: :error, mode: "unknown", summary: "Status check failed", reason: reason}
  end

  def normalize_response(other) do
    %{status: :error, mode: "unknown", summary: "Unexpected status response", reason: other}
  end

  def apply_async_result(socket, {:ok, statuses}) when is_map(statuses) do
    socket
    |> Phoenix.Component.assign(:ingress_statuses, statuses)
    |> Phoenix.Component.assign(:ingress_status_loading, %{})
  end

  def apply_async_result(socket, _result) do
    socket
    |> Phoenix.Component.assign(:ingress_statuses, %{})
    |> Phoenix.Component.assign(:ingress_status_loading, %{})
  end
end

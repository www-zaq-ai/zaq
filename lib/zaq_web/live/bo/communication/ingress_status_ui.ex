defmodule ZaqWeb.Live.BO.Communication.IngressStatusUI do
  @moduledoc false

  def color(status) do
    case status && (status[:status] || status["status"]) do
      :ok -> "status-success"
      "ok" -> "status-success"
      :error -> "status-error"
      "error" -> "status-error"
      _ -> "status-neutral"
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

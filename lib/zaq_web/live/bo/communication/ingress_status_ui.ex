defmodule ZaqWeb.Live.BO.Communication.IngressStatusUI do
  @moduledoc false

  def color(status) do
    status
    |> status_value()
    |> status_color()
  end

  def label(status) do
    case status_value(status) do
      :ok -> "Ready"
      :pending -> "Checking"
      :error -> "Unavailable"
      :disabled -> "Disabled"
      _ -> "Unknown"
    end
  end

  def tone(status) do
    case status_value(status) do
      :ok -> :success
      :pending -> :warning
      :error -> :danger
      _ -> :neutral
    end
  end

  @doc "Collects connector observations concurrently without leaking failed-check diagnostics."
  @spec collect([map()], (map() -> map())) :: [map()]
  def collect(configs, fetch_status) do
    configs
    |> Task.async_stream(&safe_fetch(fetch_status, &1),
      max_concurrency: 4,
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Enum.zip(configs)
    |> Enum.map(&connector_result/1)
  end

  defp safe_fetch(fetch_status, config) do
    fetch_status.(config)
  rescue
    _error -> %{status: :unknown, summary: "Readiness check unavailable"}
  catch
    _kind, _reason -> %{status: :unknown, summary: "Readiness check unavailable"}
  end

  defp connector_result({{:ok, status}, config}),
    do: %{id: config.id, name: config.name, status: status}

  defp connector_result({_failure, config}),
    do: %{
      id: config.id,
      name: config.name,
      status: %{status: :unknown, summary: "Readiness check unavailable"}
    }

  @doc "Aggregates enabled connector health without treating provider ambiguity as failure."
  def aggregate([]), do: %{status: :unsupported, summary: "No enabled connectors", connectors: []}

  def aggregate([%{status: status}] = connectors), do: Map.put(status, :connectors, connectors)

  def aggregate(connectors) do
    values = Enum.map(connectors, &status_value(&1.status))
    healthy = Enum.count(values, &(&1 in [:ok, "ok"]))

    status =
      cond do
        healthy == length(values) -> :ok
        Enum.all?(values, &(&1 in [:error, "error"])) -> :error
        Enum.any?(values, &(&1 in [:unknown, "unknown"])) -> :unknown
        true -> :pending
      end

    %{
      status: status,
      summary: "#{healthy}/#{length(values)} connectors healthy",
      connectors: connectors
    }
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
    socket =
      socket
      |> Phoenix.Component.assign(:ingress_statuses, statuses)
      |> Phoenix.Component.assign(:ingress_status_loading, %{})

    case socket.assigns[:ingress_status_modal] do
      %{provider: provider} = modal ->
        Phoenix.Component.assign(socket, :ingress_status_modal, %{
          modal
          | status: Map.get(statuses, provider)
        })

      _ ->
        socket
    end
  end

  def apply_async_result(socket, _result) do
    socket
    |> Phoenix.Component.assign(:ingress_statuses, %{})
    |> Phoenix.Component.assign(:ingress_status_loading, %{})
  end
end

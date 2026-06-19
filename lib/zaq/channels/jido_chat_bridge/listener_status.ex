defmodule Zaq.Channels.JidoChatBridge.ListenerStatus do
  @moduledoc false

  @auth_timeout 250

  def auth_status(pid, timeout \\ @auth_timeout) when is_pid(pid) do
    ref = make_ref()
    monitor_ref = Process.monitor(pid)

    send(pid, {:auth_status, self(), ref})

    receive do
      {^ref, status} ->
        Process.demonitor(monitor_ref, [:flush])
        {:ok, status}

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:error, reason}
    after
      timeout ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, :timeout}
    end
  end

  def status_from_auth(:ok) do
    %{status: :ok, summary: "Ingress listener authenticated"}
  end

  def status_from_auth(status) when status in [:pending, :unknown] do
    %{status: :pending, summary: "Ingress listener is connecting and authenticating"}
  end

  def status_from_auth({:error, :timeout}) do
    %{status: :pending, summary: "Ingress listener authentication status is pending"}
  end

  def status_from_auth({:error, reason}), do: from_exit_reason(reason)

  def status_from_auth(_status) do
    %{status: :pending, summary: "Ingress listener authentication status is unknown"}
  end

  def from_exit_reason(:normal), do: nil
  def from_exit_reason(:shutdown), do: nil
  def from_exit_reason({:shutdown, _reason}), do: nil

  def from_exit_reason({:auth_failed, reason}) do
    %{
      status: :error,
      summary: "Ingress listener authentication failed",
      reason: reason
    }
  end

  def from_exit_reason({:transport_failed, reason}) do
    %{
      status: :error,
      summary: "Ingress listener connection failed",
      reason: reason
    }
  end

  def from_exit_reason(reason) do
    %{
      status: :error,
      summary: "Ingress listener stopped",
      reason: reason
    }
  end

  def query_listener_pids(listener_pids) when is_list(listener_pids) do
    listener_pids
    |> Enum.filter(&(is_pid(&1) and Process.alive?(&1)))
    |> Enum.map(&auth_status/1)
    |> status_from_auth_results()
  end

  defp status_from_auth_results([]), do: nil

  defp status_from_auth_results(results) do
    cond do
      Enum.any?(results, &(&1 == {:ok, :ok})) ->
        status_from_auth(:ok)

      error = Enum.find(results, &match?({:error, reason} when reason != :timeout, &1)) ->
        status_from_auth(error)

      true ->
        %{status: :pending, summary: "Ingress listener is connecting and authenticating"}
    end
  end
end

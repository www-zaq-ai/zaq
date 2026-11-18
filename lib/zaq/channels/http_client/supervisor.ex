defmodule Zaq.Channels.HttpClient.Supervisor do
  @moduledoc """
  Owns request workers and their outbound lease manager as one failure domain.

  Restarting either child closes all request-scoped sockets. This prevents orphaned
  peers or surviving leases from being adopted by a replacement manager.
  The first HTTP request starts this subtree under `Channels.BridgeSupervisor`;
  the generic Channels parent retains its two existing children.
  """

  use Supervisor

  alias Zaq.Channels.HttpClient.Pool

  @doc "Ensures the HTTP runtime is owned by the existing dynamic Channels subtree."
  @spec ensure_started(keyword()) :: :ok | {:error, term()}
  def ensure_started(opts \\ []) do
    if Process.whereis(Keyword.get(opts, :name, Pool)) do
      :ok
    else
      runtime = Keyword.get(opts, :runtime, Zaq.Channels.BridgeSupervisor)

      case DynamicSupervisor.start_child(runtime, {__MODULE__, Keyword.delete(opts, :runtime)}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  catch
    :exit, _reason -> {:error, :closed}
  end

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :supervisor, __MODULE__))
  end

  @impl true
  def init(opts) do
    connections = Keyword.get(opts, :connections, Zaq.Channels.HttpClient.Connections)

    Supervisor.init(
      [
        {Task.Supervisor, name: connections},
        {Pool, Keyword.put(opts, :connections, connections)}
      ],
      strategy: :one_for_all
    )
  end
end

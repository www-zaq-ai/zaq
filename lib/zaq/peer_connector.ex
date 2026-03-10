defmodule Zaq.PeerConnector do
  @moduledoc """
  Connects to peer nodes reactively using :net_kernel.monitor_nodes/1.

  Instead of polling, this GenServer subscribes to node up/down events.
  When a peer listed in NODES comes online, it connects immediately.

  Called from application.ex after the supervision tree starts:

      Zaq.PeerConnector.start_link([])

  Controlled via the NODES env var:

      NODES=ai@localhost,channels@localhost mix phx.server
  """

  use GenServer

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    expected = parse_peers()

    if expected == [] do
      :ignore
    else
      # Subscribe to node up/down events
      :net_kernel.monitor_nodes(true)

      # Try connecting to any that are already up
      remaining = connect_available(expected)

      if remaining == [] do
        Logger.info("[PeerConnector] All peer nodes connected.")
        {:ok, %{remaining: []}, {:continue, :stop}}
      else
        Logger.info("[PeerConnector] Waiting for nodes: #{inspect(remaining)}")
        {:ok, %{remaining: remaining}}
      end
    end
  end

  @impl true
  def handle_continue(:stop, state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    if node in state.remaining do
      Logger.info("[PeerConnector] Connected to peer node: #{node}")
      remaining = List.delete(state.remaining, node)

      if remaining == [] do
        Logger.info("[PeerConnector] All peer nodes connected.")
        :net_kernel.monitor_nodes(false)
        {:stop, :normal, %{state | remaining: []}}
      else
        Logger.info("[PeerConnector] Still waiting for: #{inspect(remaining)}")
        {:noreply, %{state | remaining: remaining}}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:nodedown, node}, state) do
    Logger.warning("[PeerConnector] Peer node went down: #{node}")
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp connect_available(peers) do
    Enum.reduce(peers, [], fn node, remaining ->
      case Node.connect(node) do
        true ->
          Logger.info("[PeerConnector] Connected to peer node: #{node}")
          remaining

        _ ->
          [node | remaining]
      end
    end)
  end

  defp parse_peers do
    case System.get_env("NODES") do
      nil ->
        []

      nodes_str ->
        nodes_str
        |> String.split(",")
        |> Enum.map(&(&1 |> String.trim() |> String.to_atom()))
    end
  end
end

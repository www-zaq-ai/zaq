defmodule Zaq.PeerConnector do
  @moduledoc """
  Auto-discovers and connects to peer nodes via EPMD — no NODES env var needed.

  On startup and on every nodeup event, queries EPMD for all named nodes
  running on the same host and attempts to connect to each. Nodes with a
  different cookie are silently skipped by the Erlang runtime.

  Broadcasts node up/down events via Phoenix.PubSub so LiveViews can
  react without managing their own monitor_nodes subscriptions.

  ## PubSub messages

      {:node_up, node_name}
      {:node_down, node_name}

  ## Usage

      # Subscribe in a LiveView
      Phoenix.PubSub.subscribe(Zaq.PubSub, "node:events")

      def handle_info({:node_up, _node}, socket), do: ...
      def handle_info({:node_down, _node}, socket), do: ...

  ## Dev commands — no NODES needed

      ROLES=bo           iex --sname bo@localhost       --cookie zaq_dev -S mix phx.server
      ROLES=agent,ingestion iex --sname ai@localhost    --cookie zaq_dev -S mix
      ROLES=channels     iex --sname channels@localhost --cookie zaq_dev -S mix
  """

  use GenServer

  require Logger

  @topic "node:events"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    deps = deps_from_opts(opts)

    deps.monitor_nodes.(true)
    connect_epmd_peers(deps)

    {:ok, %{deps: deps}}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    deps = deps_from_state(state)

    deps.log_info.("[PeerConnector] Node up: #{node}")
    deps.pubsub_broadcast.(Zaq.PubSub, @topic, {:node_up, node})
    connect_epmd_peers(deps)

    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    deps = deps_from_state(state)

    deps.log_warning.("[PeerConnector] Node down: #{node}")
    deps.pubsub_broadcast.(Zaq.PubSub, @topic, {:node_down, node})

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp connect_epmd_peers(deps) do
    host = deps.host.()

    case deps.epmd_names.(host) do
      {:ok, entries} ->
        entries
        |> Enum.map(fn {name, _port} -> :"#{name}@#{host}" end)
        |> Enum.reject(&(&1 == deps.self_node.()))
        |> Enum.each(&connect_peer(&1, deps))

      {:error, reason} ->
        deps.log_debug.("[PeerConnector] EPMD query failed: #{inspect(reason)}")
    end
  end

  defp connect_peer(node, deps) do
    case deps.node_connect.(node) do
      true ->
        deps.log_info.("[PeerConnector] Connected to: #{node}")

      false ->
        deps.log_debug.(
          "[PeerConnector] Could not connect to: #{node} (different cookie or unreachable)"
        )

      :ignored ->
        deps.log_debug.("[PeerConnector] Not distributed, skipping: #{node}")
    end
  end

  defp deps_from_state(%{deps: deps}), do: deps
  defp deps_from_state(_state), do: deps_from_opts([])

  defp deps_from_opts(opts) do
    %{
      monitor_nodes: Keyword.get(opts, :monitor_nodes_fun, &:net_kernel.monitor_nodes/1),
      epmd_names: Keyword.get(opts, :epmd_names_fun, &:erl_epmd.names/1),
      self_node: Keyword.get(opts, :self_node_fun, &node/0),
      node_connect: Keyword.get(opts, :node_connect_fun, &Node.connect/1),
      pubsub_broadcast: Keyword.get(opts, :pubsub_broadcast_fun, &Phoenix.PubSub.broadcast/3),
      host: Keyword.get(opts, :host_fun, &host/0),
      log_info: Keyword.get(opts, :log_info_fun, &Logger.info/1),
      log_warning: Keyword.get(opts, :log_warning_fun, &Logger.warning/1),
      log_debug: Keyword.get(opts, :log_debug_fun, &Logger.debug/1)
    }
  end

  defp host do
    node()
    |> Atom.to_string()
    |> String.split("@")
    |> List.last()
    |> String.to_charlist()
  end
end

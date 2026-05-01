defmodule Zaq.Agent.StatusBroadcaster do
  @moduledoc """
  Telemetry handler that broadcasts agent pipeline status events to BO chat sessions.

  Listens to Jido AI telemetry events and reads session context from the calling
  process's dictionary (`:zaq_status_context`). Because telemetry handlers run
  synchronously in the emitting process, the process dictionary key is set by
  `Factory.ask_with_config` before the ask and cleaned up in a `try/after` block.

  Runs alongside `JidoObservabilityLogger` — each has a single concern.
  This module broadcasts; the logger logs. They attach to the same events independently.
  """

  use GenServer

  require Logger

  alias Zaq.Agent.{Factory, Status}

  @handler_id "zaq-agent-status-broadcaster"

  @events [
    [:jido, :ai, :llm, :start],
    [:jido, :ai, :tool, :start],
    [:jido, :ai, :tool, :execute, :start]
  ]

  @default_mcp_prefixes ["mcp__", "mcp_"]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, %{}) do
      :ok ->
        {:ok, %{}}

      {:error, reason} ->
        Logger.warning("StatusBroadcaster disabled: telemetry attach failed: #{inspect(reason)}")
        {:ok, %{}}
    end
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  @doc false
  def handle_event([:jido, :ai, :llm, :start], _measurements, metadata, _config) do
    case resolve_ctx(metadata) do
      nil -> :ok
      ctx -> Status.broadcast(ctx, :thinking, "Thinking…", ctx.node_router)
    end

    :ok
  end

  def handle_event(event, _measurements, metadata, _config)
      when event in [[:jido, :ai, :tool, :start], [:jido, :ai, :tool, :execute, :start]] do
    case resolve_ctx(metadata) do
      nil ->
        :ok

      ctx ->
        tool_name = Map.get(metadata, :tool_name) || "unknown"
        stage = tool_stage(tool_name)
        Status.broadcast(ctx, stage, "Calling #{tool_name}…", ctx.node_router)
        existing = Process.get(:zaq_tool_calls, [])
        Process.put(:zaq_tool_calls, existing ++ [%{name: tool_name, type: stage}])
    end

    :ok
  end

  defp resolve_ctx(metadata) do
    proc_ctx = Process.get(:zaq_status_context)

    session_id =
      (proc_ctx && proc_ctx.session_id) ||
        case Factory.spawn_opts_from_server_id(Map.get(metadata, :agent_id)) do
          %{conversation_id: id} when is_binary(id) and id != "" -> id
          _ -> nil
        end

    request_id = proc_ctx && proc_ctx.request_id
    node_router = (proc_ctx && proc_ctx.node_router) || Zaq.NodeRouter

    if session_id && request_id do
      %{session_id: session_id, request_id: request_id, node_router: node_router}
    end
  end

  defp tool_stage(tool_name) when is_binary(tool_name) do
    mcp_prefixes = Application.get_env(:zaq, :mcp_tool_prefixes, @default_mcp_prefixes)

    if Enum.any?(mcp_prefixes, &String.starts_with?(tool_name, &1)),
      do: :mcp_call,
      else: :tool_call
  end

  defp tool_stage(_), do: :tool_call
end

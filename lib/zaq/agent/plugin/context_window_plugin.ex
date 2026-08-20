defmodule Zaq.Agent.Plugin.ContextWindowPlugin do
  @moduledoc """
  Keeps a configured agent's `Jido.AI.Context` inside its
  `memory_context_max_size` budget across the server's whole lifetime.

  - **Cold spawn** — `mount/2` hydrates the context from conversation history
    (via `Zaq.Agent.HistoryLoader`, using the scope encoded in the server id)
    and trims it to the budget. A context supplied by the caller — a workflow
    step assembling its own turns — is trimmed but never replaced.
  - **Warm server** — `prepare_signal/2` trims the live context after each
    completed request and casts `ai.react.context.modify` back at the server, so
    a long-lived conversation cannot grow past its budget between spawns.

  Per-turn trimming is not handled here: a plugin cannot own `:__strategy__`
  (the key collides with the agent schema at compile time), so the per-turn seam
  is `Zaq.Agent.ContextWindow` installed as the ReAct `request_transformer` in
  `Zaq.Agent.Factory`.
  """

  use Jido.Plugin,
    name: "context_window",
    description: "Bounds the agent's LLM context to its configured token budget",
    state_key: :context,
    actions: [],
    signal_patterns: ["ai.request.completed"]

  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.AI.Context, as: AIContext
  alias Zaq.Agent.{ContextWindow, Factory, HistoryLoader}

  require Logger

  @impl Jido.Plugin
  def mount(agent, _config) do
    budget = budget(agent)

    context =
      case Map.get(agent.state, :context) do
        %AIContext{} = supplied -> supplied
        _ -> load_history(agent, budget)
      end

    {:ok, ContextWindow.fit(context, budget)}
  end

  @impl Jido.Plugin
  def prepare_signal(signal, %{agent: agent}) do
    context = agent |> StratState.get(%{}) |> Map.get(:context)

    with %AIContext{} <- context,
         budget <- budget(agent),
         fitted when fitted.entries != context.entries <- ContextWindow.fit(context, budget) do
      Jido.AgentServer.cast(self(), compaction_signal(fitted))
    end

    {:ok, signal, %{}}
  end

  def prepare_signal(signal, _context), do: {:ok, signal, %{}}

  defp compaction_signal(context) do
    Jido.Signal.new!(%{
      type: "ai.react.context.modify",
      source: "zaq:agent:context_window",
      data: %{
        operation: %{
          type: :replace,
          # `:compaction` is the sanctioned reason for a size-driven rewrite —
          # the strategy rejects any value outside its known set.
          reason: :compaction,
          result_context: context
        }
      }
    })
  end

  defp load_history(agent, budget) do
    agent.id
    |> Factory.spawn_opts_from_server_id()
    |> HistoryLoader.load_context(max_tokens: budget)
  rescue
    error ->
      Logger.warning(
        "ContextWindow could not hydrate history for #{inspect(agent.id)}: " <>
          Exception.message(error)
      )

      AIContext.new()
  end

  defp budget(agent) do
    agent.state
    |> Map.get(:tool_context, %{})
    |> Map.get(:memory_context_max_size)
  end
end

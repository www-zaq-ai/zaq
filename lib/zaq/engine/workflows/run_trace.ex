defmodule Zaq.Engine.Workflows.RunTrace do
  @moduledoc """
  Per-run execution trace appended to a plain-text file — the scheduler's view
  of a workflow run, durable across IEx scrollback.

  Opt-in and OFF by default: tracing activates only when
  `config :zaq, :workflow_trace_dir` is set, which `config/runtime.exs` does when
  the app is started with `WORKFLOW_TRACE_ENABLED=true` (destination overridable
  via `WORKFLOW_TRACE_DIR`, default `tmp/workflow_traces`). When active, every
  run appends to `<trace_dir>/run_<run_id>.log`:

  - the initial input fact (`run started`),
  - after every Runic react cycle: the facts produced during that cycle (with
    the node that produced each, resolved from the fact's ancestry) and the
    `next_runnables` Runic scheduled for the following cycle,
  - every step and edge execution (start, result, condition pass/skip) as
    written by `StepRunner` and `Steps.EdgeStep`,
  - the quiescent final state (`run quiescent`) and the finalize outcome.

  This exists because `StepRun` rows only capture steps that *entered*
  `StepRunner` — a node Runic never schedules leaves no row and no log line.
  The trace shows what the scheduler saw each cycle, so a "gate never ran" run
  can be diagnosed from the file alone.

  Tracing is a diagnostic aid, never a correctness gate: every entry point is
  wrapped in a rescue/catch and a failure to trace can never affect the run.
  Unset `:workflow_trace_dir` (the default) disables all writes.

  Cycle state (fact hashes already reported, node-hash → name index, cycle
  counter) lives in the process dictionary of the process driving the run —
  execution is sequential, so `start/3` / `cycle/2` / `final/2` all run in the
  `WorkflowRunAgent` process. `step/4` is stateless and safe from any process.
  """

  alias Runic.Workflow
  alias Runic.Workflow.Fact

  @state_key :zaq_workflow_run_trace_state

  @inspect_opts [pretty: true, limit: 500, printable_limit: 10_000, structs: true, width: 100]

  @spec enabled?() :: boolean()
  def enabled?, do: trace_dir() != nil

  @doc "Absolute path of the trace file for a run, or `nil` when tracing is disabled."
  @spec path(String.t()) :: String.t() | nil
  def path(run_id) do
    case trace_dir() do
      nil -> nil
      dir -> Path.join(dir, "run_#{run_id}.log")
    end
  end

  @doc """
  Opens the trace for a run: resets per-run cycle state, indexes the DAG's
  node hashes → names (for resolving fact ancestry), writes the header entry.
  """
  @spec start(String.t(), Workflow.t(), map()) :: :ok
  def start(run_id, dag, input) do
    safely(fn ->
      node_names = node_name_index(dag)
      Process.put(@state_key, %{cycle: 0, seen: MapSet.new(), node_names: node_names})

      write(run_id, "run started", %{
        run_id: run_id,
        graph_nodes: map_size(node_names),
        input: input
      })
    end)
  end

  @doc """
  Records one react cycle from the post-cycle workflow: facts newly produced
  this cycle (attributed to their producing node) and the runnables Runic
  scheduled for the next cycle. Called from the run's `:checkpoint`.
  """
  @spec cycle(String.t(), Workflow.t()) :: :ok
  def cycle(run_id, workflow) do
    safely(fn ->
      state = Process.get(@state_key) || %{cycle: 0, seen: MapSet.new(), node_names: %{}}
      facts = Workflow.facts(workflow)
      new_facts = Enum.reject(facts, &MapSet.member?(state.seen, &1.hash))
      cycle = state.cycle + 1
      seen = Enum.reduce(new_facts, state.seen, &MapSet.put(&2, &1.hash))
      Process.put(@state_key, %{state | cycle: cycle, seen: seen})

      write(run_id, "react cycle #{cycle}", %{
        new_facts: Enum.map(new_facts, &fact_entry(&1, state.node_names)),
        next_runnables: runnable_entries(workflow, state.node_names)
      })
    end)
  end

  @doc """
  Records the quiescent end state: total fact count and any runnables Runic
  still holds (should be none — leftovers are exactly the "never scheduled"
  evidence the trace exists to capture).
  """
  @spec final(String.t(), Workflow.t()) :: :ok
  def final(run_id, workflow) do
    safely(fn ->
      state = Process.get(@state_key) || %{node_names: %{}}
      Process.delete(@state_key)

      write(run_id, "run quiescent", %{
        is_runnable: Workflow.is_runnable?(workflow),
        leftover_runnables: runnable_entries(workflow, state.node_names),
        total_facts: length(Workflow.facts(workflow))
      })
    end)
  end

  @doc """
  Records a discrete engine event — step start/result from `StepRunner`, edge
  condition pass/skip from `Steps.EdgeStep`, finalize outcome from
  `WorkflowRunAgent`. Stateless; safe from any process.
  """
  @spec step(String.t() | nil, String.t(), String.t() | nil, term()) :: :ok
  def step(nil, _label, _step_name, _data), do: :ok

  def step(run_id, label, step_name, data) do
    safely(fn ->
      write(run_id, [label, step_name && " — #{step_name}"] |> Enum.join(), data)
    end)
  end

  defp runnable_entries(workflow, node_names) do
    for {node, fact} <- Workflow.next_runnables(workflow) do
      %{node: node_label(node), input_fact: fact_entry(fact, node_names)}
    end
  end

  defp fact_entry(%Fact{} = fact, node_names) do
    %{
      produced_by: producer_label(fact.ancestry, node_names),
      value: fact.value
    }
  end

  defp producer_label(nil, _node_names), do: :input

  defp producer_label({producer_hash, _parent_fact_hash}, node_names),
    do: Map.get(node_names, producer_hash, producer_hash)

  defp producer_label(_other, _node_names), do: :unknown

  # Index every named vertex of the Runic graph by hash so fact ancestry
  # (which only carries hashes) can be reported as node names.
  defp node_name_index(%Workflow{graph: graph}) do
    for %{hash: hash} = vertex <- Multigraph.vertices(graph),
        name = Map.get(vertex, :name),
        not is_nil(name),
        into: %{} do
      {hash, name}
    end
  end

  defp node_name_index(_), do: %{}

  defp node_label(%{name: name} = node) when not is_nil(name),
    do: "#{name} (#{node_type(node)})"

  defp node_label(node), do: node_type(node)

  defp node_type(%struct{}), do: struct |> Module.split() |> List.last()
  defp node_type(other), do: inspect(other)

  defp write(run_id, label, data) do
    case path(run_id) do
      nil ->
        :ok

      file ->
        File.mkdir_p!(Path.dirname(file))

        entry = [
          "\n=== [",
          DateTime.to_iso8601(DateTime.utc_now()),
          "] ",
          label,
          " ===\n",
          inspect(data, @inspect_opts),
          "\n"
        ]

        File.write!(file, entry, [:append])
    end
  end

  # A trace failure must never affect the run — swallow everything, but leave
  # a breadcrumb in the standard log so a broken trace setup is discoverable.
  defp safely(fun) do
    fun.()
    :ok
  rescue
    e ->
      require Logger
      Logger.warning("[workflow] run trace write failed: #{Exception.message(e)}")
      :ok
  catch
    kind, reason ->
      require Logger
      Logger.warning("[workflow] run trace write failed: #{inspect({kind, reason})}")
      :ok
  end

  defp trace_dir, do: Application.get_env(:zaq, :workflow_trace_dir)
end

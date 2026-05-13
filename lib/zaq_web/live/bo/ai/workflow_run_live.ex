defmodule ZaqWeb.Live.BO.AI.WorkflowRunLive do
  @moduledoc """
  BO page — full log trail for a single workflow run.

  Subscribes to `"workflow_run:<run_id>"` on mount and receives live updates
  from WorkflowAgent as steps execute.
  """
  use ZaqWeb, :live_view

  import ZaqWeb.Live.BO.AI.WorkflowComponents

  alias Zaq.{Event, NodeRouter}
  alias ZaqWeb.Components.BOLayout

  @impl true
  def mount(%{"id" => workflow_id, "run_id" => run_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Zaq.PubSub, "workflow_run:#{run_id}")
    end

    case fetch_trace(run_id, socket) do
      {:ok, workflow, run, step_runs} ->
        {:ok,
         assign(socket,
           current_path: "/bo/workflows/#{workflow_id}/runs/#{run_id}",
           workflow: workflow,
           run: run,
           step_runs: step_runs
         )}

      :error ->
        {:ok, push_navigate(socket, to: ~p"/bo/workflows/#{workflow_id}")}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # ── PubSub handlers ─────────────────────────────────────────────

  @impl true
  def handle_info({:run_updated, run}, socket) do
    {:noreply, assign(socket, run: run)}
  end

  def handle_info({:step_updated, step_run}, socket) do
    step_runs =
      Enum.map(socket.assigns.step_runs, fn sr ->
        if sr.id == step_run.id, do: step_run, else: sr
      end)

    # If new step not yet in list, append it
    step_runs =
      if Enum.any?(step_runs, &(&1.id == step_run.id)),
        do: step_runs,
        else: step_runs ++ [step_run]

    {:noreply, assign(socket, step_runs: Enum.sort_by(step_runs, & &1.step_index))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <BOLayout.bo_layout
      current_user={@current_user}
      flash={@flash}
      page_title={"Run — #{short_id(@run.id)}"}
      current_path={@current_path}
      features_version={@features_version}
    >
      <div class="max-w-5xl mx-auto">
        <%!-- Breadcrumb --%>
        <nav class="font-mono text-[0.75rem] text-black mb-5 flex items-center gap-1.5">
          <.link navigate={~p"/bo/workflows"} class="text-black/50 hover:text-black transition-colors">
            Workflows
          </.link>
          <span class="text-black/30">/</span>
          <.link
            navigate={~p"/bo/workflows/#{@workflow.id}"}
            class="text-black/50 hover:text-black transition-colors"
          >
            {@workflow.name}
          </.link>
          <span class="text-black/30">/</span>
          <span class="text-black font-semibold">Run {short_id(@run.id)}</span>
        </nav>

        <%!-- Run header --%>
        <div class="mb-6">
          <h2 class="font-mono text-[1rem] font-bold text-black">
            Run <code class="text-[0.9em] font-mono">{short_id(@run.id)}</code>
          </h2>
          <div class="flex items-center gap-3 mt-2">
            <.run_status_badge status={@run.status} />
            <span class="font-mono text-[0.75rem] text-black/60">
              Started {format_dt(@run.started_at)} · <.run_duration run={@run} />
            </span>
          </div>
        </div>

        <%!-- Execution path DAG --%>
        <div class="mb-6">
          <p class="font-mono text-[0.7rem] font-semibold text-black/50 uppercase tracking-wider mb-3">
            Execution Path
          </p>
          <div class="bg-white rounded-xl border border-black/[0.08] p-5">
            <.workflow_dag
              nodes={(@run.steps_snapshot || %{})["nodes"] || []}
              edges={(@run.steps_snapshot || %{})["edges"] || []}
              step_runs={@step_runs}
            />
          </div>
        </div>

        <%!-- Steps timeline --%>
        <div class="space-y-3">
          <p class="font-mono text-[0.7rem] font-semibold text-black/50 uppercase tracking-wider">
            Steps
          </p>

          <p
            :if={@step_runs == []}
            class="bg-white rounded-xl border border-black/[0.08] font-mono text-[0.85rem] text-black/50 text-center py-10"
          >
            No steps recorded yet.
          </p>

          <div
            :for={step <- @step_runs}
            class="bg-white rounded-xl border border-black/[0.08] overflow-hidden"
          >
            <%!-- Step header --%>
            <div class="flex items-center justify-between px-5 py-3 border-b border-black/[0.06] bg-black/[0.01]">
              <div class="flex items-center gap-3">
                <span class="font-mono text-[0.72rem] text-black/40 w-5 text-right tabular-nums">
                  {step.step_index + 1}
                </span>
                <span class="font-mono text-[0.85rem] font-semibold text-black">
                  {step.step_name}
                </span>
              </div>
              <div class="flex items-center gap-3">
                <.run_duration run={step} />
                <.run_status_badge status={step.status} />
              </div>
            </div>

            <%!-- Logs --%>
            <div :if={step.logs != []} class="px-5 py-3 border-b border-black/[0.06] space-y-1">
              <p class="font-mono text-[0.65rem] font-semibold text-black/40 uppercase tracking-wider mb-2">
                Logs
              </p>
              <.step_log_entry :for={log <- step.logs} log={log} />
            </div>

            <%!-- Errors --%>
            <div :if={step.status == "failed" and step.errors != nil} class="px-5 py-3 bg-red-50">
              <p class="font-mono text-[0.65rem] font-semibold text-red-500 uppercase tracking-wider mb-2">
                Error
              </p>
              <pre class="font-mono text-[0.75rem] text-red-700 whitespace-pre-wrap break-all">{inspect(step.errors, pretty: true)}</pre>
            </div>
          </div>
        </div>
      </div>
    </BOLayout.bo_layout>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp fetch_trace(run_id, _socket) do
    dispatch = fn mod, fun, args ->
      Event.new(%{module: mod, function: fun, args: args}, :engine)
      |> NodeRouter.dispatch()
      |> Map.get(:response)
    end

    run = dispatch.(Zaq.Engine.Workflows, :get_run!, [run_id])
    workflow = dispatch.(Zaq.Engine.Workflows, :get_workflow!, [run.workflow_id])
    step_runs = dispatch.(Zaq.Engine.Workflows, :list_step_runs, [run_id])

    {:ok, workflow, run, step_runs || []}
  rescue
    _ -> :error
  end

  defp short_id(nil), do: "?"
  defp short_id(id), do: String.slice(id, 0, 8)

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
end

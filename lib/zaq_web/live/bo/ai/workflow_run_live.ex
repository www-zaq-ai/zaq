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
    case fetch_trace(run_id, socket) do
      {:ok, workflow, run, step_runs, approval} ->
        if connected?(socket), do: subscribe_and_start(run_id, run)

        {:ok,
         assign(socket,
           current_path: "/bo/workflows/#{workflow_id}/runs/#{run_id}",
           workflow: workflow,
           run: run,
           step_runs: step_runs,
           approval: approval,
           now: DateTime.utc_now()
         )}

      :error ->
        {:ok, push_navigate(socket, to: ~p"/bo/workflows/#{workflow_id}")}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # ── PubSub handlers ─────────────────────────────────────────────

  @impl true
  def handle_info({:start_run, run}, socket) do
    Task.start(fn ->
      Event.new(%{module: Zaq.Engine.Workflows, function: :start_run, args: [run]}, :engine)
      |> NodeRouter.dispatch()
    end)

    {:noreply, socket}
  end

  def handle_info(:tick, socket) do
    if socket.assigns.run.status in ["pending", "running"] do
      {:noreply, assign(socket, now: DateTime.utc_now())}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:run_updated, run}, socket) do
    socket = assign(socket, run: run)

    socket =
      if run.status == "waiting" do
        assign(socket, approval: fetch_approval(run.id))
      else
        assign(socket, approval: nil)
      end

    {:noreply, socket}
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

  # ── Events ──────────────────────────────────────────────────────

  @impl true
  def handle_event("cancel_run", _params, socket) do
    run = socket.assigns.run

    event =
      Event.new(
        %{module: Zaq.Engine.Workflows, function: :cancel_run, args: [run]},
        :engine
      )

    case NodeRouter.dispatch(event).response do
      {:ok, updated_run} ->
        {:noreply, assign(socket, run: updated_run)}

      {:error, :already_finished} ->
        {:noreply, put_flash(socket, :error, "Run has already finished.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to cancel run.")}
    end
  end

  def handle_event("pause_run", _params, socket) do
    run = socket.assigns.run

    event =
      Event.new(
        %{module: Zaq.Engine.Workflows, function: :pause_run, args: [run]},
        :engine
      )

    case NodeRouter.dispatch(event).response do
      {:ok, updated_run} ->
        {:noreply, assign(socket, run: updated_run)}

      {:error, :not_running} ->
        {:noreply, put_flash(socket, :error, "Run is not currently running.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to pause run.")}
    end
  end

  def handle_event("resume_run", _params, socket) do
    run = socket.assigns.run

    Task.start(fn ->
      Event.new(
        %{module: Zaq.Engine.Workflows, function: :resume_run, args: [run]},
        :engine
      )
      |> NodeRouter.dispatch()
    end)

    {:noreply, socket}
  end

  def handle_event("approve_run", _params, socket) do
    run = socket.assigns.run

    request = %{action: "run.approve", run_id: run.id, person_id: nil, decision: %{}}

    case NodeRouter.dispatch(
           Event.new(request, :engine, opts: [action: :workflow, skip_permissions: true])
         ).response do
      {:ok, updated_run} ->
        {:noreply, assign(socket, run: updated_run, approval: nil)}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to approve run.")}
    end
  end

  def handle_event("reject_run", _params, socket) do
    run = socket.assigns.run

    request = %{action: "run.reject", run_id: run.id, person_id: nil, reason: "Rejected via BO"}

    case NodeRouter.dispatch(
           Event.new(request, :engine, opts: [action: :workflow, skip_permissions: true])
         ).response do
      {:ok, updated_run} ->
        {:noreply, assign(socket, run: updated_run, approval: nil)}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to reject run.")}
    end
  end

  # ── Private helpers ─────────────────────────────────────────────

  defp subscribe_and_start(run_id, run) do
    Phoenix.PubSub.subscribe(Zaq.PubSub, "workflow_run:#{run_id}")
    if run.status == "pending", do: send(self(), {:start_run, run})

    if run.status in ["pending", "running"],
      do: :timer.send_interval(1_000, self(), :tick)
  end

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
      <div>
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
        <div class="flex items-start justify-between mb-6">
          <div>
            <h2 class="font-mono text-[1rem] font-bold text-black">
              Run <code class="text-[0.9em] font-mono">{short_id(@run.id)}</code>
            </h2>
            <div class="flex items-center gap-3 mt-2">
              <.run_status_badge status={@run.status} />
              <span class="font-mono text-[0.75rem] text-black/60">
                Started {format_dt(@run.started_at)} · <.run_duration run={@run} now={@now} />
              </span>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <button
              :if={@run.status == "running"}
              phx-click="pause_run"
              class="font-mono text-[0.82rem] px-4 py-2 rounded-lg border border-black/10 text-black/50 hover:bg-black/[0.03] transition-colors"
            >
              Pause
            </button>
            <button
              :if={@run.status == "paused"}
              phx-click="resume_run"
              class="font-mono text-[0.82rem] px-4 py-2 rounded-lg border border-[#03b6d4]/30 text-[#03b6d4] hover:bg-[#03b6d4]/10 transition-colors"
            >
              Resume
            </button>
            <button
              :if={@run.status in ["pending", "running", "paused", "waiting"]}
              phx-click="cancel_run"
              class="font-mono text-[0.82rem] px-4 py-2 rounded-lg border border-orange-200 text-orange-600 hover:bg-orange-50 transition-colors"
            >
              Cancel
            </button>
            <button
              :if={@run.status == "waiting"}
              phx-click="approve_run"
              class="font-mono text-[0.82rem] px-4 py-2 rounded-lg border border-green-200 text-green-700 hover:bg-green-50 transition-colors"
            >
              Approve
            </button>
            <button
              :if={@run.status == "waiting"}
              phx-click="reject_run"
              class="font-mono text-[0.82rem] px-4 py-2 rounded-lg border border-red-200 text-red-600 hover:bg-red-50 transition-colors"
            >
              Reject
            </button>
          </div>
        </div>

        <%!-- Approval review card --%>
        <div
          :if={@run.status == "waiting" and @approval != nil}
          class="mb-6 bg-amber-50 rounded-xl border border-amber-200 p-5"
        >
          <p class="font-mono text-[0.7rem] font-semibold text-amber-600 uppercase tracking-wider mb-3">
            Waiting for Review
          </p>
          <div class="space-y-1 mb-4">
            <p class="font-mono text-[0.82rem] text-black/70">
              Step: <span class="font-semibold text-black">{@approval.step_name}</span>
            </p>
            <p :if={@approval.message} class="font-mono text-[0.82rem] text-black/70">
              {@approval.message}
            </p>
          </div>

          <%!-- Prior step outputs for review (collapsible) --%>
          <% review_steps = review_steps(@step_runs, @approval.step_name) %>
          <div :if={review_steps != []} class="border-t border-amber-200 pt-4">
            <button
              type="button"
              phx-click={
                JS.toggle(to: "#hitl-review-content")
                |> JS.toggle_class("rotate-90", to: "#hitl-review-chevron")
              }
              class="cursor-pointer flex items-center gap-2 select-none mb-3"
            >
              <span class="font-mono text-[0.65rem] font-semibold text-amber-600/70 uppercase tracking-wider">
                Content to Review
              </span>
              <svg
                id="hitl-review-chevron"
                class="w-3 h-3 text-amber-400 transition-transform"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                viewBox="0 0 24 24"
              >
                <path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7" />
              </svg>
            </button>
            <div id="hitl-review-content" style="display:none" class="space-y-4">
              <div :for={sr <- review_steps} class="space-y-1">
                <p class="font-mono text-[0.7rem] text-black/50">{sr.step_name}</p>
                <div class="bg-white/70 rounded-lg border border-amber-100 p-3">
                  <ZaqWeb.Components.JsonTree.json_tree
                    id={"jt-hitl-#{sr.id}"}
                    data={clean_results(sr.results)}
                  />
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- Execution path DAG --%>
        <div class="mb-6">
          <p class="font-mono text-[0.7rem] font-semibold text-black/50 uppercase tracking-wider mb-3">
            Execution Path
          </p>
          <div
            class="bg-white rounded-xl border border-black/[0.08] p-5"
            style="background-image: linear-gradient(#21dfff 0.5px, transparent 0.5px), linear-gradient(90deg, #e3e3e3 0.5px, transparent 0.5px); background-size: 20px 20px;"
          >
            <.workflow_dag
              nodes={(@run.steps_snapshot || %{})["nodes"] || []}
              edges={(@run.steps_snapshot || %{})["edges"] || []}
              step_runs={@step_runs}
            />
          </div>
        </div>

        <%!-- Steps timeline --%>
        <% visible = visible_steps(@step_runs) %>
        <div class="space-y-3">
          <p class="font-mono text-[0.7rem] font-semibold text-black/50 uppercase tracking-wider">
            Steps
          </p>

          <p
            :if={visible == []}
            class="bg-white rounded-xl border border-black/[0.08] font-mono text-[0.85rem] text-black/50 text-center py-10"
          >
            No steps recorded yet.
          </p>

          <div
            :for={step <- visible}
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
                <.run_duration run={step} now={@now} />
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

            <%!-- Output (collapsible) --%>
            <% step_output = clean_results(step.results) %>
            <div
              :if={step.status in ["completed", "waiting"] and map_size(step_output) > 0}
              class="border-b border-black/[0.06]"
            >
              <button
                type="button"
                phx-click={
                  JS.toggle(to: "#step-output-#{step.id}")
                  |> JS.toggle_class("rotate-90", to: "#step-chevron-#{step.id}")
                }
                class="w-full px-5 py-3 cursor-pointer flex items-center gap-2 select-none hover:bg-black/[0.01] transition-colors"
              >
                <span class="font-mono text-[0.65rem] font-semibold text-black/40 uppercase tracking-wider">
                  Output
                </span>
                <svg
                  id={"step-chevron-#{step.id}"}
                  class="w-3 h-3 text-black/30 transition-transform"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2"
                  viewBox="0 0 24 24"
                >
                  <path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7" />
                </svg>
              </button>
              <div id={"step-output-#{step.id}"} style="display:none" class="px-5 pb-3">
                <ZaqWeb.Components.JsonTree.json_tree
                  id={"jt-step-#{step.id}"}
                  data={step_output}
                />
              </div>
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

  defp fetch_approval(run_id) do
    Event.new(
      %{module: Zaq.Engine.Workflows, function: :get_pending_approval, args: [run_id]},
      :engine
    )
    |> NodeRouter.dispatch()
    |> Map.get(:response)
  end

  defp fetch_trace(run_id, _socket) do
    dispatch = fn mod, fun, args ->
      Event.new(%{module: mod, function: fun, args: args}, :engine)
      |> NodeRouter.dispatch()
      |> Map.get(:response)
    end

    run = dispatch.(Zaq.Engine.Workflows, :get_run!, [run_id])
    workflow = dispatch.(Zaq.Engine.Workflows, :get_workflow!, [run.workflow_id])
    step_runs = dispatch.(Zaq.Engine.Workflows, :list_step_runs, [run_id])

    approval =
      if run.status == "waiting",
        do: dispatch.(Zaq.Engine.Workflows, :get_pending_approval, [run.id]),
        else: nil

    {:ok, workflow, run, step_runs || [], approval}
  rescue
    _ -> :error
  end

  defp visible_steps(step_runs) do
    Enum.reject(step_runs, fn sr ->
      String.contains?(sr.step_name, "__to__") and String.ends_with?(sr.step_name, "__edge")
    end)
  end

  defp review_steps(step_runs, waiting_step_name) do
    step_runs
    |> Enum.filter(fn sr ->
      sr.status == "completed" and sr.step_name != waiting_step_name and
        map_size(clean_results(sr.results)) > 0
    end)
  end

  defp clean_results(nil), do: %{}

  defp clean_results(results) when is_map(results) do
    results
    |> Map.drop(["__cascade__", :__cascade__])
    |> Enum.reject(fn {_k, v} -> is_map(v) and Map.has_key?(v, "__cascade__") end)
    |> Map.new()
  end

  defp short_id(nil), do: "?"
  defp short_id(id), do: String.slice(id, 0, 8)

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
end

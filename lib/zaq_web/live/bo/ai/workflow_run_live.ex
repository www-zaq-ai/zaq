defmodule ZaqWeb.Live.BO.AI.WorkflowRunLive do
  @moduledoc """
  BO page — full log trail for a single workflow run.

  Subscribes to `"workflow_run:<run_id>"` on mount and receives live updates
  from WorkflowRunAgent as steps execute.

  In addition to the standard `:step_updated` / `:run_updated` messages,
  handles real-time chunk progress from Batch nodes:

  - `{:batch_progress, step_name, progress}` — chunk progress from Batch
  """
  use ZaqWeb, :live_view

  import ZaqWeb.Live.BO.AI.WorkflowComponents

  alias Zaq.{Event, NodeRouter}
  alias ZaqWeb.Components.BOLayout
  alias ZaqWeb.Live.BO.AI.WorkflowResultHelpers

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
           now: DateTime.utc_now(),
           node_info: build_node_info(run),
           batch_progress: %{},
           selected_step: active_step(step_runs)
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

    step_runs =
      if Enum.any?(step_runs, &(&1.id == step_run.id)),
        do: step_runs,
        else: step_runs ++ [step_run]

    step_runs = Enum.sort_by(step_runs, & &1.step_index)

    # Auto-focus the currently running step; manual selection is preserved otherwise.
    socket =
      if step_run.status == "running" do
        assign(socket, selected_step: step_run.step_name)
      else
        socket
      end

    {:noreply, assign(socket, step_runs: step_runs)}
  end

  # Live chunk progress from Batch — update batch_progress for this step.
  def handle_info({:batch_progress, step_name, progress}, socket) do
    {:noreply, update(socket, :batch_progress, &Map.put(&1, step_name, progress))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Events ──────────────────────────────────────────────────────

  @impl true
  def handle_event("select_step", %{"step_name" => step_name}, socket) do
    selected =
      if socket.assigns.selected_step == step_name, do: nil, else: step_name

    {:noreply, assign(socket, selected_step: selected)}
  end

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
        # Optimistically flip any "running" step_runs to "paused" so the badge
        # and frozen duration are visible immediately (before the PubSub round-trip).
        paused_at = DateTime.utc_now(:second)
        updated_step_runs = Enum.map(socket.assigns.step_runs, &pause_step_run(&1, paused_at))
        {:noreply, assign(socket, run: updated_run, step_runs: updated_step_runs)}

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

  def handle_event("retry_run", _params, socket) do
    run = socket.assigns.run
    workflow = socket.assigns.workflow

    event =
      Event.new(
        %{module: Zaq.Engine.Workflows, function: :retry_run, args: [run]},
        :engine
      )

    case NodeRouter.dispatch(event).response do
      {:ok, new_run} ->
        {:noreply, push_navigate(socket, to: ~p"/bo/workflows/#{workflow.id}/runs/#{new_run.id}")}

      {:error, :not_retryable} ->
        {:noreply, put_flash(socket, :error, "Run cannot be retried.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to retry run.")}
    end
  end

  def handle_event("approve_step", _params, socket) do
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

  def handle_event("reject_step", _params, socket) do
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

  # Returns the step_name of the currently running step, or nil.
  # Used on mount to pre-select the active step when loading a live run.
  defp active_step(step_runs) do
    Enum.find_value(step_runs, fn sr ->
      if sr.status == "running", do: sr.step_name
    end)
  end

  defp subscribe_and_start(run_id, run) do
    Phoenix.PubSub.subscribe(Zaq.PubSub, "workflow_run:#{run_id}")
    if run.status == "pending", do: send(self(), {:start_run, run})

    if run.status in ["pending", "running"],
      do: :timer.send_interval(1_000, self(), :tick)
  end

  # Builds a map of step_name → %{is_batch, is_map, params} from the run's
  # steps_snapshot.  Used to route each step to the correct card component.
  defp build_node_info(run) do
    (run.steps_snapshot || %{})
    |> Map.get("nodes", [])
    |> Map.new(fn n ->
      mod = n["module"]

      {n["name"],
       %{
         is_batch: batch_module?(mod),
         is_map: n["type"] == "map",
         params: n["params"] || %{}
       }}
    end)
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
              phx-click="approve_step"
              class="font-mono text-[0.82rem] px-4 py-2 rounded-lg border border-green-200 text-green-700 hover:bg-green-50 transition-colors"
            >
              Approve
            </button>
            <button
              :if={@run.status == "waiting"}
              phx-click="reject_step"
              class="font-mono text-[0.82rem] px-4 py-2 rounded-lg border border-red-200 text-red-600 hover:bg-red-50 transition-colors"
            >
              Reject
            </button>
            <button
              :if={@run.status == "failed"}
              phx-click="retry_run"
              class="font-mono text-[0.82rem] px-4 py-2 rounded-lg border border-[#03b6d4]/30 text-[#03b6d4] hover:bg-[#03b6d4]/10 transition-colors"
            >
              Retry
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

        <%!-- Interrupted notice --%>
        <div
          :if={@run.status == "interrupted"}
          class="mb-6 bg-yellow-50 rounded-xl border border-yellow-200 p-4 flex items-start justify-between gap-4"
        >
          <div>
            <p class="font-mono text-[0.7rem] font-semibold text-yellow-700 uppercase tracking-wider mb-1">
              Run Interrupted
            </p>
            <p class="font-mono text-[0.82rem] text-black/60">
              This run was interrupted when the server restarted. Any steps that were
              in progress have been marked as failed.
            </p>
          </div>
          <button
            phx-click="retry_run"
            class="flex-shrink-0 font-mono text-[0.82rem] px-4 py-2 rounded-lg border border-[#03b6d4]/30 text-[#03b6d4] hover:bg-[#03b6d4]/10 transition-colors"
          >
            Retry
          </button>
        </div>

        <%!-- Failure summary banner --%>
        <% failed_steps = Enum.filter(@step_runs, &(&1.status == "failed")) %>
        <% build_error = get_in(@run.log_summary, ["error"]) %>
        <div
          :if={@run.status == "failed"}
          class="mb-6 bg-red-50 rounded-xl border border-red-200 p-4 space-y-3"
        >
          <%= if failed_steps != [] do %>
            <p class="font-mono text-[0.7rem] font-semibold text-red-600 uppercase tracking-wider">
              {length(failed_steps)} step{if length(failed_steps) > 1, do: "s"} failed
            </p>
            <div :for={sr <- failed_steps} class="space-y-1">
              <p class="font-mono text-[0.82rem] font-semibold text-black">{sr.step_name}</p>
              <pre
                :if={sr.errors != nil}
                class="font-mono text-[0.73rem] text-red-700 whitespace-pre-wrap break-all bg-red-100/60 rounded-lg px-3 py-2"
              >{format_step_error(sr.errors)}</pre>
            </div>
          <% else %>
            <p class="font-mono text-[0.7rem] font-semibold text-red-600 uppercase tracking-wider">
              Run failed before any step executed
            </p>
            <pre
              :if={build_error != nil}
              class="font-mono text-[0.73rem] text-red-700 whitespace-pre-wrap break-all bg-red-100/60 rounded-lg px-3 py-2"
            >{build_error}</pre>
          <% end %>
        </div>

        <%!-- DAG + optional step detail panel --%>
        <% all_visible = visible_steps(@step_runs) %>
        <% visible =
          if @selected_step,
            do: Enum.filter(all_visible, &(&1.step_name == @selected_step)),
            else: [] %>
        <div class={[
          "flex gap-6 items-start transition-all duration-300",
          if(@selected_step, do: "", else: "")
        ]}>
          <%!-- DAG: full-width when nothing selected, half-width when a node is active --%>
          <div class={[
            "sticky top-6 transition-all duration-300",
            if(@selected_step, do: "w-1/2", else: "w-full")
          ]}>
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
                on_node_click={true}
                selected_step={@selected_step}
              />
            </div>
          </div>

          <%!-- Right: Steps panel — only rendered when a node is selected --%>
          <div :if={@selected_step} class="w-1/2 space-y-3">
            <p class="font-mono text-[0.7rem] font-semibold text-black/50 uppercase tracking-wider">
              {@selected_step}
            </p>

            <%= if @selected_step == "start" do %>
              <%!-- Virtual origin: show the trigger payload, not a StepRun. --%>
              <.start_input_card run={@run} />
            <% else %>
              <p
                :if={visible == []}
                class="bg-white rounded-xl border border-black/[0.08] font-mono text-[0.85rem] text-black/50 text-center py-10"
              >
                No steps recorded yet.
              </p>

              <%= for step <- visible do %>
                <% info = Map.get(@node_info, step.step_name, %{}) %>
                <%= cond do %>
                  <% Map.get(info, :is_batch) -> %>
                    <.batch_step_card
                      step={step}
                      batch_progress={Map.get(@batch_progress, step.step_name)}
                      step_runs={@step_runs}
                      node_params={Map.get(info, :params, %{})}
                      now={@now}
                    />
                  <% Map.get(info, :is_map) -> %>
                    <.map_step_card
                      step={step}
                      step_runs={@step_runs}
                      node_params={Map.get(info, :params, %{})}
                      now={@now}
                    />
                  <% true -> %>
                    <%!-- Generic step card --%>
                    <div class="bg-white rounded-xl border border-black/[0.08] overflow-hidden">
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
                      <div
                        :if={step.logs != []}
                        class="px-5 py-3 border-b border-black/[0.06] space-y-1"
                      >
                        <p class="font-mono text-[0.65rem] font-semibold text-black/40 uppercase tracking-wider mb-2">
                          Logs
                        </p>
                        <.step_log_entry :for={log <- step.logs} log={log} />
                      </div>

                      <%!-- Input (collapsible) --%>
                      <div
                        :if={not is_nil(step.input) and map_size(step.input) > 0}
                        class="border-b border-black/[0.06]"
                      >
                        <button
                          type="button"
                          phx-click={
                            JS.toggle(to: "#step-input-#{step.id}")
                            |> JS.toggle_class("rotate-90", to: "#step-input-chevron-#{step.id}")
                          }
                          class="w-full px-5 py-3 cursor-pointer flex items-center gap-2 select-none hover:bg-black/[0.01] transition-colors"
                        >
                          <span class="font-mono text-[0.65rem] font-semibold text-black/40 uppercase tracking-wider">
                            Input
                          </span>
                          <svg
                            id={"step-input-chevron-#{step.id}"}
                            class="w-3 h-3 text-black/30 transition-transform"
                            fill="none"
                            stroke="currentColor"
                            stroke-width="2"
                            viewBox="0 0 24 24"
                          >
                            <path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7" />
                          </svg>
                        </button>
                        <div
                          id={"step-input-#{step.id}"}
                          phx-update="ignore"
                          style="display:none"
                          class="px-5 pb-3"
                        >
                          <ZaqWeb.Components.JsonTree.json_tree
                            id={"jt-step-input-#{step.id}"}
                            data={step.input}
                          />
                        </div>
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
                      <div
                        :if={step.status == "failed" and step.errors != nil}
                        class="px-5 py-3 bg-red-50"
                      >
                        <p class="font-mono text-[0.65rem] font-semibold text-red-500 uppercase tracking-wider mb-2">
                          Error
                        </p>
                        <pre class="font-mono text-[0.75rem] text-red-700 whitespace-pre-wrap break-all">{inspect(step.errors, pretty: true)}</pre>
                      </div>
                    </div>
                <% end %>
              <% end %>
            <% end %>
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

  defp pause_step_run(%{status: "running"} = sr, paused_at),
    do: %{sr | status: "paused", finished_at: paused_at}

  defp pause_step_run(sr, _paused_at), do: sr

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

  defp clean_results(results), do: WorkflowResultHelpers.clean_results(results)

  defp format_step_error(%{"message" => msg}) when is_binary(msg), do: msg
  defp format_step_error(%{"reason" => reason}) when is_binary(reason), do: reason
  defp format_step_error(errors), do: inspect(errors, pretty: true)

  defp short_id(nil), do: "?"
  defp short_id(id), do: String.slice(id, 0, 8)

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
end

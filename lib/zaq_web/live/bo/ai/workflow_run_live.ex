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
  import ZaqWeb.Components.MarkdownEditor, only: [markdown_view: 1]

  alias Zaq.{Event, NodeRouter}
  alias ZaqWeb.Components.BOLayout
  alias ZaqWeb.Live.BO.AI.WorkflowResultHelpers
  alias ZaqWeb.Live.BO.Communication.MessageHelpers

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
           selected_step: active_step(step_runs),
           expanded_trace_ids: %{},
           agents_by_id: fetch_agents_by_id((run.steps_snapshot || %{})["nodes"] || [])
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
      Event.new(%{module: Zaq.Engine.Workflows, function: :start_run_async, args: [run]}, :engine)
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
    # A running fork sub-step focuses its parent node so the iteration shows inside
    # that node's batch card instead of as a standalone per-fork card.
    socket =
      if step_run.status == "running" do
        assign(socket, selected_step: parent_node_name(step_run.step_name))
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

  def handle_event(
        "toggle_step_trace_details",
        %{"step_run_id" => sid, "trace_id" => tid},
        socket
      ) do
    current = Map.get(socket.assigns.expanded_trace_ids, sid, MapSet.new())

    updated =
      Map.put(
        socket.assigns.expanded_trace_ids,
        sid,
        MessageHelpers.toggle_trace_details(current, tid)
      )

    {:noreply, assign(socket, :expanded_trace_ids, updated)}
  end

  def handle_event("copy_message", %{"text" => text}, socket) do
    {:noreply, push_event(socket, "clipboard", %{text: text})}
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
        %{module: Zaq.Engine.Workflows, function: :resume_run_async, args: [run]},
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

  # Returns the node name of the currently running step, or nil. A running map/Batch
  # fork sub-step (`<node>/<step>[i]`) resolves to its parent node so the iteration
  # stays inside that node's batch card rather than popping out a per-fork card.
  # Used on mount to pre-select the active step when loading a live run.
  defp active_step(step_runs) do
    Enum.find_value(step_runs, fn sr ->
      if sr.status == "running", do: parent_node_name(sr.step_name)
    end)
  end

  # A map/Batch fork sub-step StepRun is named `<node>/<step>[i]`. Returns the
  # parent node name for such a name, or the name unchanged otherwise.
  defp parent_node_name(step_name) when is_binary(step_name) do
    case Regex.run(~r{^(.+?)/.+\[\d+\]$}, step_name) do
      [_, node] -> node
      _ -> step_name
    end
  end

  defp parent_node_name(other), do: other

  defp fork_sub_step?(step_name) when is_binary(step_name),
    do: String.contains?(step_name, "/") and Regex.match?(~r/\[\d+\]$/, step_name)

  defp fork_sub_step?(_), do: false

  defp subscribe_and_start(run_id, run) do
    Phoenix.PubSub.subscribe(Zaq.PubSub, "workflow_run:#{run_id}")
    if run.status == "pending", do: send(self(), {:start_run, run})

    if run.status in ["pending", "running"],
      do: :timer.send_interval(1_000, self(), :tick)
  end

  # Builds a map of step_name → %{is_batch, is_map, index, params} from the run's
  # steps_snapshot.  Used to route each step to the correct card component (and to
  # synthesize a live batch step while it is still fanning out).
  defp build_node_info(run) do
    (run.steps_snapshot || %{})
    |> Map.get("nodes", [])
    |> Map.new(fn n ->
      mod = n["module"]

      {n["name"],
       %{
         is_batch: batch_module?(mod),
         is_map: n["type"] == "map",
         index: n["index"] || 0,
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
                Started {format_datetime_seconds(@run.started_at)} ·
                <.run_duration run={@run} now={@now} />
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
            <span class="font-mono text-[0.65rem] font-semibold text-amber-600/70 uppercase tracking-wider mb-3 block">
              Content to Review
            </span>
            <div id="hitl-review-content" class="space-y-3">
              <% review =
                review_steps
                |> Enum.map(&{&1, review_content_text(clean_results(&1.results))})
                |> Enum.with_index()

              last_index = length(review) - 1 %>
              <div :for={{{sr, content_text}, idx} <- review} class="space-y-1">
                <button
                  type="button"
                  phx-click={
                    JS.toggle(to: "#hitl-review-item-#{sr.id}")
                    |> JS.toggle_class("rotate-90", to: "#hitl-review-item-chevron-#{sr.id}")
                  }
                  class="cursor-pointer flex items-center gap-2 select-none"
                >
                  <svg
                    id={"hitl-review-item-chevron-#{sr.id}"}
                    class={[
                      "w-3 h-3 text-amber-400 transition-transform flex-shrink-0",
                      idx == last_index && "rotate-90"
                    ]}
                    fill="none"
                    stroke="currentColor"
                    stroke-width="2"
                    viewBox="0 0 24 24"
                  >
                    <path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7" />
                  </svg>
                  <p class="font-mono text-[0.7rem] text-black/50">{sr.step_name}</p>
                </button>
                <div
                  id={"hitl-review-item-#{sr.id}"}
                  style={if idx != last_index, do: "display:none"}
                >
                  <.markdown_view :if={content_text} id={"md-hitl-#{sr.id}"} content={content_text} />
                  <div
                    :if={is_nil(content_text)}
                    class="bg-white/70 rounded-lg border border-amber-100 p-3"
                  >
                    <ZaqWeb.Components.JsonTree.json_tree
                      id={"jt-hitl-#{sr.id}"}
                      data={clean_results(sr.results)}
                    />
                  </div>
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
              {interrupted_reason(@step_runs)}
            </p>
          </div>
          <button
            phx-click="retry_run"
            class="flex-shrink-0 font-mono text-[0.82rem] px-4 py-2 rounded-lg border border-[#03b6d4]/30 text-[#03b6d4] hover:bg-[#03b6d4]/10 transition-colors"
          >
            Retry
          </button>
        </div>

        <%!-- Incomplete notice — surfaces WHERE the run stopped and WHY. An
             "incomplete" run reached quiescence without any terminal step
             completing: either a branch condition was evaluated false and its
             subgraph pruned, or a gate/condition node was the boundary the run
             never got past. We name the last step that ran, the gate involved
             (with the actual value it hinges on, resolved from the last output),
             and the ordered list of steps that never ran — so the operator can act. --%>
        <% inc = incomplete_details(@run, @step_runs) %>
        <div
          :if={@run.status == "incomplete"}
          class="mb-6 bg-amber-50 rounded-xl border border-amber-200 p-4 space-y-3"
        >
          <div>
            <p class="font-mono text-[0.7rem] font-semibold text-amber-700 uppercase tracking-wider mb-1">
              Run Incomplete
            </p>
            <p class="font-mono text-[0.82rem] text-black/60">
              <%= if inc.stopped_after do %>
                Execution stopped after
                <span class="font-semibold text-black">{inc.stopped_after}</span>
                — no terminal step ran.
              <% else %>
                This run ended without completing the workflow — no terminal step ran.
              <% end %>
            </p>
          </div>

          <%!-- Explicit edge conditions that evaluated false (skipped edge rows). --%>
          <div :if={inc.unmet != []} class="space-y-2">
            <p class="font-mono text-[0.65rem] font-semibold text-amber-600/80 uppercase tracking-wider">
              Condition{if length(inc.unmet) > 1, do: "s"} not met
            </p>
            <div
              :for={c <- inc.unmet}
              class="bg-white/70 rounded-lg border border-amber-100 px-3 py-2 space-y-0.5"
            >
              <p class="font-mono text-[0.78rem] font-semibold text-black">{c.label}</p>
              <p class="font-mono text-[0.75rem] text-black/60">{c.sentence}</p>
            </div>
          </div>

          <%!-- The condition gate at the boundary, with the actual value it hinges on. --%>
          <div
            :if={inc.gate}
            class="bg-white/70 rounded-lg border border-amber-100 px-3 py-2 space-y-1.5"
          >
            <p class="font-mono text-[0.78rem] font-semibold text-black">
              {inc.gate.name} <span class="text-black/40 font-normal">— condition gate</span>
            </p>
            <div
              :for={c <- inc.gate.conditions}
              class="font-mono text-[0.75rem] text-black/60"
            >
              {c.description} — <span class="text-black/80">current value: {c.current}</span>
            </div>
            <p class="font-mono text-[0.7rem] text-amber-700/80">
              This gate was never reached, so the run stopped before it. Check the value above and the workflow's routing.
            </p>
          </div>

          <div :if={inc.never_reached != []} class="space-y-1">
            <p class="font-mono text-[0.65rem] font-semibold text-amber-600/80 uppercase tracking-wider">
              Steps never reached
            </p>
            <p class="font-mono text-[0.8rem] text-black/70">{Enum.join(inc.never_reached, ", ")}</p>
          </div>
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
        <% visible = selected_step_cards(@selected_step, all_visible, @node_info, @step_runs, @run) %>
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
                agents_by_id={@agents_by_id}
              />
            </div>
          </div>

          <%!-- Right: Steps panel — only rendered when a node is selected.
               min-w-0 stops wide step content (e.g. long trace JSON lines) from
               inflating this flex item past w-1/2; inner overflow-x-auto
               regions then scroll instead of stretching the page. --%>
          <div :if={@selected_step} class="w-1/2 min-w-0 space-y-3">
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

                      <%!-- Agent trace (inline, always visible when present) --%>
                      <div
                        :if={
                          step.status in ["completed", "waiting"] and
                            agent_trace_available?(step.results)
                        }
                        class="border-b border-black/[0.06] px-5 py-3"
                      >
                        <ZaqWeb.Components.AgentTracePanel.agent_trace_panel
                          message_info={agent_trace_info(step.results)}
                          expanded_ids={Map.get(@expanded_trace_ids, step.id, MapSet.new())}
                          toggle_event="toggle_step_trace_details"
                          testid={"agent-trace-panel-#{step.id}"}
                          phx-value-step_run_id={step.id}
                        />
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

  # Bulk-resolves the `agent_id`s referenced by `type: "agent"` nodes in the
  # run's steps_snapshot so the DAG can render each run_agent step's
  # configured name/model.
  defp fetch_agents_by_id(nodes) do
    case extract_agent_ids(nodes) do
      [] ->
        %{}

      agent_ids ->
        case Event.new(
               %{module: Zaq.Agent, function: :get_agents_by_ids, args: [agent_ids]},
               :agent
             )
             |> NodeRouter.dispatch()
             |> Map.get(:response) do
          agents when is_map(agents) -> agents
          _ -> %{}
        end
    end
  rescue
    _ -> %{}
  end

  defp pause_step_run(%{status: "running"} = sr, paused_at),
    do: %{sr | status: "paused", finished_at: paused_at}

  defp pause_step_run(sr, _paused_at), do: sr

  defp visible_steps(step_runs) do
    Enum.reject(step_runs, fn sr ->
      edge_step?(sr.step_name) or fork_sub_step?(sr.step_name)
    end)
  end

  defp edge_step?(step_name),
    do: String.contains?(step_name, "__to__") and String.ends_with?(step_name, "__edge")

  # The StepRun(s) for the selected node — its own row(s), or a synthesized batch step
  # from the fork rows while a map/Batch node's aggregate row (written last) is missing.
  defp selected_step_cards(nil, _all_visible, _node_info, _step_runs, _run), do: []
  defp selected_step_cards("start", _all_visible, _node_info, _step_runs, _run), do: []

  defp selected_step_cards(selected, all_visible, node_info, step_runs, run) do
    case Enum.filter(all_visible, &(&1.step_name == selected)) do
      [] -> List.wrap(synthetic_batch_step(selected, node_info, step_runs, run))
      found -> found
    end
  end

  # Placeholder for a map/Batch node whose aggregate row isn't written yet (`nil`
  # otherwise). Status mirrors the run so a terminal run shows "failed", not "running".
  defp synthetic_batch_step(node_name, node_info, step_runs, run) do
    info = Map.get(node_info, node_name, %{})

    forks =
      Enum.filter(
        step_runs,
        &(fork_sub_step?(&1.step_name) and parent_node_name(&1.step_name) == node_name)
      )

    if (Map.get(info, :is_batch) or Map.get(info, :is_map)) and forks != [] do
      status = synthetic_batch_status(run.status)

      %{
        id: "live-#{node_name}",
        step_name: node_name,
        step_index: Map.get(info, :index, 0),
        status: status,
        logs: [],
        input: nil,
        results: nil,
        errors: nil,
        started_at: earliest_started_at(forks),
        finished_at: if(status == "running", do: nil, else: run.finished_at)
      }
    end
  end

  # A terminal run never reached MapCollect, so the fanning-out node was interrupted
  # mid-fan-out → "failed", not a stuck "running" badge.
  defp synthetic_batch_status(status) when status in ["running", "pending"], do: "running"
  defp synthetic_batch_status("paused"), do: "paused"
  defp synthetic_batch_status(_terminal), do: "failed"

  defp earliest_started_at(forks) do
    forks
    |> Enum.map(& &1.started_at)
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> case do
      [] -> nil
      dts -> Enum.min(dts, DateTime)
    end
  end

  # The generated text a human is meant to review before approving (e.g. the
  # agent-drafted email body from `RunAgent`, keyed `output`). Falls back to
  # `nil` — and the JsonTree — when a step's results carry structured data
  # instead of a single reviewable block of prose.
  defp review_content_text(results) do
    case Map.get(results, "output") || Map.get(results, :output) do
      text when is_binary(text) and text != "" -> text
      _ -> nil
    end
  end

  defp review_steps(step_runs, waiting_step_name) do
    step_runs
    |> Enum.filter(fn sr ->
      sr.status == "completed" and sr.step_name != waiting_step_name and
        map_size(clean_results(sr.results)) > 0
    end)
  end

  defp clean_results(results), do: WorkflowResultHelpers.clean_results(results)
  defp agent_trace_info(results), do: WorkflowResultHelpers.agent_trace_info(results)
  defp agent_trace_available?(results), do: WorkflowResultHelpers.agent_trace_available?(results)

  defp format_step_error(%{"message" => msg}) when is_binary(msg), do: msg
  defp format_step_error(%{"reason" => reason}) when is_binary(reason), do: reason
  defp format_step_error(errors), do: inspect(errors, pretty: true)

  # The interrupted-run banner used to show a single hardcoded sentence
  # ("...when the server restarted") regardless of why the run actually
  # stopped. `interrupt_run/2` bulk-marks every in-flight StepRun with the
  # *same* errors payload for one interruption event, so any one of them is
  # representative — pick the first that actually carries a recognized
  # interruption reason (as opposed to an unrelated step failure that
  # predates the interruption) and show its real message.
  @interruption_reasons ["node_shutdown", "process_terminated"]

  defp interrupted_reason(step_runs) do
    step_runs
    |> Enum.find(fn sr ->
      sr.status == "failed" and get_in(sr.errors, ["reason"]) in @interruption_reasons
    end)
    |> case do
      nil ->
        "This run was interrupted. Any steps that were in progress have been marked as failed."

      step_run ->
        "#{format_step_error(step_run.errors)} Any steps that were in progress have been marked as failed."
    end
  end

  @condition_module "Zaq.Agent.Tools.Workflow.Condition"

  # Assembles everything the incomplete banner needs to explain an incomplete run:
  #   - `stopped_after`  — the last authored node that actually completed
  #   - `unmet`          — edge conditions that evaluated false (skipped edge rows)
  #   - `gate`           — the first unreached Condition node (the boundary), with
  #                        its conditions rendered and the ACTUAL value each hinges
  #                        on, resolved from the last completed step's output
  #   - `never_reached`  — the ordered authored nodes that never ran
  defp incomplete_details(run, step_runs) do
    nodes = snapshot_nodes(run)

    completed =
      for sr <- step_runs, sr.status == "completed", into: MapSet.new(), do: sr.step_name

    stopped_after =
      nodes
      |> Enum.filter(&MapSet.member?(completed, &1["name"]))
      |> List.last()
      |> then(&(&1 && &1["name"]))

    never_reached =
      nodes
      |> Enum.reject(&MapSet.member?(completed, &1["name"]))
      |> Enum.map(& &1["name"])

    %{
      stopped_after: stopped_after,
      never_reached: never_reached,
      gate: detect_gate(nodes, completed, step_runs),
      unmet: unmet_conditions(step_runs)
    }
  end

  defp snapshot_nodes(run) do
    (run.steps_snapshot || %{})
    |> Map.get("nodes", [])
    |> Enum.sort_by(&(&1["index"] || 0))
  end

  # The first authored Condition node that never ran — the recency/routing gate the
  # run stopped short of. Its `params.conditions` are what the run hinged on; we
  # resolve each condition's referenced value from the completed step outputs so the
  # banner can show, e.g., `total.last_message_date must be on or after now − 5
  # minutes — current value: null`.
  defp detect_gate(nodes, completed, step_runs) do
    node =
      Enum.find(nodes, fn n ->
        n["module"] == @condition_module and not MapSet.member?(completed, n["name"])
      end)

    if node do
      %{name: node["name"], conditions: resolve_condition_values(node, step_runs)}
    end
  end

  defp resolve_condition_values(node, step_runs) do
    base = resolve_ref(get_in(node, ["params", "input"]), step_runs)

    (get_in(node, ["params", "conditions"]) || [])
    |> Enum.map(fn c ->
      %{description: condition_requirement(c), current: render_val(dig(base, c["key"]))}
    end)
  end

  # A dotted `"<step>.<path...>"` reference (a Condition node's `input`) resolved
  # against the completed step outputs — the same shape the engine's FactLookup reads.
  defp resolve_ref(ref, step_runs) when is_binary(ref) do
    case String.split(ref, ".") do
      [step | path] ->
        step_runs
        |> Enum.find(&(&1.step_name == step))
        |> then(&(&1 && &1.results))
        |> dig(path)

      _ ->
        nil
    end
  end

  defp resolve_ref(_ref, _step_runs), do: nil

  defp dig(val, key) when is_binary(key), do: dig(val, String.split(key, "."))
  defp dig(nil, _path), do: nil
  defp dig(val, []), do: val
  defp dig(map, [k | rest]) when is_map(map), do: dig(Map.get(map, k), rest)
  defp dig(_val, _path), do: nil

  # Human-readable requirement clause for one condition, mirroring the Condition
  # tool's own phrasing (`docs/services/workflows.md`).
  defp condition_requirement(c) do
    key = c["key"] || "value"
    op = c["op"] || "eq"

    cond do
      op == "not_empty" ->
        "#{key} must not be empty"

      op == "empty" ->
        "#{key} must be empty"

      c["type"] in ["date", "datetime"] ->
        "#{key} #{date_phrase(op)} #{render_expected(c["value"])}"

      true ->
        "#{key} #{plain_phrase(op)} #{render_expected(c["value"])}"
    end
  end

  defp plain_phrase("eq"), do: "must equal"
  defp plain_phrase("neq"), do: "must not equal"
  defp plain_phrase("gt"), do: "must be greater than"
  defp plain_phrase("lt"), do: "must be less than"
  defp plain_phrase("gte"), do: "must be at least"
  defp plain_phrase("lte"), do: "must be at most"
  defp plain_phrase("in"), do: "must be one of"
  defp plain_phrase(op), do: "must satisfy #{op}"

  defp date_phrase("gt"), do: "must be after"
  defp date_phrase("lt"), do: "must be before"
  defp date_phrase("gte"), do: "must be on or after"
  defp date_phrase("lte"), do: "must be on or before"
  defp date_phrase("eq"), do: "must be"
  defp date_phrase("neq"), do: "must not be"
  defp date_phrase(op), do: plain_phrase(op)

  # A relative datetime operand (`%{"from" => "now", "minutes" => -5}`) rendered as
  # `now − 5 minutes`; literals are shown as-is.
  defp render_expected(%{"from" => from} = m) do
    case Enum.find(["minutes", "hours", "days", "weeks", "months"], &Map.has_key?(m, &1)) do
      nil ->
        to_string(from)

      unit ->
        n = m[unit]
        "#{from} #{if n < 0, do: "−", else: "+"}#{abs(n)} #{unit}"
    end
  end

  defp render_expected(v) when is_binary(v), do: inspect(v)
  defp render_expected(nil), do: "empty"
  defp render_expected(v), do: inspect(v)

  defp render_val(nil), do: "null"
  defp render_val(v) when is_binary(v), do: v
  defp render_val(v), do: inspect(v)

  # Skipped edge-condition StepRuns explain WHY an incomplete run stopped short:
  # `EdgeStep` writes a "skipped" row carrying the field/op/actual/expected of a
  # condition that evaluated false and pruned the downstream subgraph. Turn each
  # into a human-readable label + sentence for the incomplete notice.
  defp unmet_conditions(step_runs) do
    step_runs
    |> Enum.filter(fn sr ->
      sr.status == "skipped" and is_map(sr.results) and
        not is_nil(field_get(sr.results, "field"))
    end)
    |> Enum.map(fn sr ->
      r = sr.results

      %{
        label: humanize_edge_name(sr.step_name),
        sentence:
          condition_sentence(
            field_get(r, "field"),
            field_get(r, "op"),
            field_get(r, "actual"),
            field_get(r, "expected")
          )
      }
    end)
  end

  # `actual`/`expected` are stored already `inspect/1`-ed by EdgeStep, so they are
  # display-ready strings (e.g. "0", "nil", "\"user\"").
  defp condition_sentence(field, op, actual, _expected) when op in ["not_empty", "empty"],
    do: "Expected #{field} #{op_phrase(op)}, but it was #{actual}."

  defp condition_sentence(field, op, actual, expected),
    do: "Expected #{field} #{op_phrase(op)} #{expected}, but it was #{actual}."

  defp op_phrase("eq"), do: "to equal"
  defp op_phrase("neq"), do: "to not equal"
  defp op_phrase("gt"), do: "to be greater than"
  defp op_phrase("lt"), do: "to be less than"
  defp op_phrase("gte"), do: "to be at least"
  defp op_phrase("lte"), do: "to be at most"
  defp op_phrase("not_empty"), do: "to be present"
  defp op_phrase("empty"), do: "to be empty"
  defp op_phrase("in"), do: "to be one of"
  defp op_phrase(other), do: "to satisfy #{other}"

  # `<from>__to__<to>__edge` → "from → to".
  defp humanize_edge_name(name) when is_binary(name) do
    case String.split(name, "__to__", parts: 2) do
      [from, rest] -> "#{from} → #{String.replace_suffix(rest, "__edge", "")}"
      _ -> name
    end
  end

  defp humanize_edge_name(name), do: name

  # Step.Run `results` is a JSONB map — string keys after a DB round-trip, atom
  # keys when delivered in-memory. Read either.
  defp field_get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, safe_existing_atom(key))
    end
  end

  defp field_get(_map, _key), do: nil

  defp safe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp short_id(nil), do: "?"
  defp short_id(id), do: String.slice(id, 0, 8)
end

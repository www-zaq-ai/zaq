defmodule ZaqWeb.Live.BO.AI.WorkflowDetailLive do
  @moduledoc """
  BO page — single workflow view with metadata, triggers, paginated run history,
  and an export action.
  """
  use ZaqWeb, :live_view

  import ZaqWeb.Live.BO.AI.WorkflowComponents

  alias Oban.Cron.Expression, as: CronExpression
  import ZaqWeb.Live.BO.AI.WorkflowRunHelpers, only: [manual_source_event: 1]

  alias Zaq.Event

  alias ZaqWeb.Components.{BOLayout, BOModal}
  alias ZaqWeb.Components.DesignSystem.Breadcrumb, as: DSBreadcrumb
  alias ZaqWeb.Components.DesignSystem.Button, as: DSButton
  alias ZaqWeb.Components.DesignSystem.Table, as: DSTable

  import DSTable,
    only: [
      table_actions: 1,
      table_badge: 1,
      table_cell: 1,
      table_datetime: 1,
      table_empty: 1,
      table_head_row: 1,
      table_row: 1,
      table_text: 1
    ]

  @per_page_options [20, 50, 100]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case fetch_workflow(id, socket) do
      {:ok, workflow} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Zaq.PubSub, "workflow:#{workflow.id}")
        end

        per_page = 20
        total = count_runs(workflow.id, socket)
        runs = fetch_runs(workflow.id, 1, per_page, socket)
        triggers = fetch_triggers(workflow.id, socket)
        agents_by_id = fetch_agents_by_id(workflow.nodes, socket)

        {:ok,
         assign(socket,
           current_path: "/bo/workflows/#{id}",
           workflow: workflow,
           triggers: triggers,
           runs: runs,
           page: 1,
           per_page: per_page,
           per_page_options: @per_page_options,
           runs_total: total,
           agents_by_id: agents_by_id,
           delete_modal_open: false,
           edit_modal_open: false,
           edit_name: workflow.name,
           edit_description: workflow.description || ""
         )}

      :error ->
        {:ok, push_navigate(socket, to: ~p"/bo/workflows")}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # ── PubSub ──────────────────────────────────────────────────────

  @impl true
  def handle_info({:run_created, _run}, socket) do
    refresh_runs(socket)
  end

  def handle_info({:run_started, _run}, socket) do
    refresh_runs(socket)
  end

  def handle_info({:run_finished, _run}, socket) do
    refresh_runs(socket)
  end

  def handle_info(:refresh_runs, socket) do
    refresh_runs(socket)
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh_runs(socket) do
    workflow_id = socket.assigns.workflow.id
    runs = fetch_runs(workflow_id, socket.assigns.page, socket.assigns.per_page, socket)
    total = count_runs(workflow_id, socket)
    {:noreply, assign(socket, runs: runs, runs_total: total)}
  end

  # ── Events ──────────────────────────────────────────────────────

  @impl true
  def handle_event("export", _params, socket) do
    event =
      Event.new(
        %{
          module: Zaq.Engine.Workflows,
          function: :export_workflow,
          args: [socket.assigns.workflow]
        },
        :engine
      )

    case node_router().dispatch(event).response do
      data when is_map(data) ->
        json = Jason.encode!(data, pretty: true)
        filename = "workflow-#{socket.assigns.workflow.id}.jsonc"
        {:noreply, push_event(socket, "download", %{filename: filename, content: json})}

      _ ->
        {:noreply, put_flash(socket, :error, "Export failed.")}
    end
  end

  # JS CronCountdown hook pushes this when the countdown reaches zero.
  # We delay 1.5 s to give Oban time to enqueue and the run to land in the DB.
  def handle_event("cron_fired", _params, socket) do
    Process.send_after(self(), :refresh_runs, 1_500)
    {:noreply, socket}
  end

  def handle_event("open_delete", _params, socket) do
    {:noreply, assign(socket, delete_modal_open: true)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, delete_modal_open: false)}
  end

  def handle_event("delete", _params, socket) do
    event =
      Event.new(
        %{
          module: Zaq.Engine.Workflows,
          function: :delete_workflow,
          args: [socket.assigns.workflow]
        },
        :engine
      )

    case node_router().dispatch(event).response do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Workflow deleted.")
         |> push_navigate(to: ~p"/bo/workflows")}

      _ ->
        {:noreply,
         socket
         |> assign(delete_modal_open: false)
         |> put_flash(:error, "Failed to delete workflow.")}
    end
  end

  def handle_event("run_workflow", %{"workflow_id" => _workflow_id}, socket) do
    workflow = socket.assigns.workflow
    source_event = manual_source_event(socket.assigns.current_user)

    run_event =
      Event.new(
        %{module: Zaq.Engine.Workflows, function: :create_run, args: [workflow, source_event]},
        :engine
      )

    case node_router().dispatch(run_event).response do
      {:ok, run} ->
        {:noreply, push_navigate(socket, to: ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to create run.")}
    end
  end

  def handle_event("toggle_status", _params, socket) do
    workflow = socket.assigns.workflow

    new_status =
      case workflow.status do
        "draft" -> "active"
        "active" -> "archived"
        "archived" -> "active"
        _ -> nil
      end

    if is_nil(new_status) do
      {:noreply, socket}
    else
      event =
        Event.new(
          %{
            module: Zaq.Engine.Workflows,
            function: :update_workflow,
            args: [workflow, %{status: new_status}]
          },
          :engine
        )

      case node_router().dispatch(event).response do
        {:ok, updated_workflow} ->
          {:noreply, assign(socket, workflow: updated_workflow)}

        _ ->
          {:noreply, put_flash(socket, :error, "Failed to update workflow status.")}
      end
    end
  end

  def handle_event("set_per_page", %{"limit" => limit_str}, socket) do
    per_page = String.to_integer(limit_str)

    if per_page in @per_page_options do
      runs = fetch_runs(socket.assigns.workflow.id, 1, per_page, socket)
      {:noreply, assign(socket, runs: runs, page: 1, per_page: per_page)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("paginate", %{"page" => page_str}, socket) do
    page = String.to_integer(page_str)
    runs = fetch_runs(socket.assigns.workflow.id, page, socket.assigns.per_page, socket)
    {:noreply, assign(socket, runs: runs, page: page)}
  end

  def handle_event("open_edit", _params, socket) do
    workflow = socket.assigns.workflow

    {:noreply,
     assign(socket,
       edit_modal_open: true,
       edit_name: workflow.name,
       edit_description: workflow.description || ""
     )}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, edit_modal_open: false)}
  end

  def handle_event("save_edit", %{"name" => name, "description" => description}, socket) do
    name = String.trim(name)

    if name == "" do
      {:noreply, put_flash(socket, :error, "Name cannot be blank.")}
    else
      event =
        Event.new(
          %{
            module: Zaq.Engine.Workflows,
            function: :update_workflow,
            args: [socket.assigns.workflow, %{name: name, description: description}]
          },
          :engine
        )

      case node_router().dispatch(event).response do
        {:ok, updated_workflow} ->
          {:noreply,
           socket
           |> assign(workflow: updated_workflow, edit_modal_open: false)
           |> put_flash(:info, "Workflow updated.")}

        _ ->
          {:noreply, put_flash(socket, :error, "Failed to update workflow.")}
      end
    end
  end

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :total_pages, max(1, ceil(assigns.runs_total / assigns.per_page)))

    ~H"""
    <BOLayout.bo_layout
      current_user={@current_user}
      flash={@flash}
      page_title={@workflow.name}
      page_subtitle={@workflow.description}
      current_path={@current_path}
      features_version={@features_version}
    >
      <:page_tag>
        <.workflow_status_badge status={@workflow.status} />
      </:page_tag>
      <div id="workflow-detail" phx-hook="WorkflowExport">
        <DSBreadcrumb.page_breadcrumb items={[
          %{label: "Workflows", to: ~p"/bo/workflows"},
          %{label: @workflow.name, current: true}
        ]} />

        <%!-- Page actions --%>
        <div class="flex items-center justify-end gap-2 mb-6">
          <DSButton.button
            variant={:primary}
            icon="hero-play"
            phx-click="run_workflow"
            phx-value-workflow_id={@workflow.id}
            title="Run workflow manually"
          >
            Run
          </DSButton.button>
          <DSButton.button variant={:secondary} phx-click="export">
            Export
          </DSButton.button>
          <DSButton.button variant={:secondary} phx-click="toggle_status">
            {toggle_status_label(@workflow.status)}
          </DSButton.button>
          <DSButton.button
            variant={:secondary}
            icon="hero-pencil-square"
            icon_only
            aria-label="Edit workflow"
            title="Edit"
            phx-click="open_edit"
          />
          <DSButton.button
            variant={:tertiary}
            danger
            icon="hero-trash"
            icon_only
            aria-label="Delete workflow"
            title="Delete"
            phx-click="open_delete"
          />
        </div>

        <%!-- Metadata + DAG side by side --%>
        <div class="flex gap-5 mb-6 items-start">
          <%!-- Details column --%>
          <div class="w-64 flex-shrink-0">
            <div class="bg-white rounded-xl border border-black/[0.08] overflow-hidden divide-y divide-black/[0.06]">
              <%!-- Stats --%>
              <div class="grid grid-cols-2 divide-x divide-black/[0.06]">
                <div class="px-4 py-3">
                  <p class="font-mono text-[0.58rem] font-semibold text-black/35 uppercase tracking-wider mb-1">
                    Runs
                  </p>
                  <p class="font-mono text-[1.1rem] font-bold text-black tabular-nums">
                    {@runs_total}
                  </p>
                </div>
                <div class="px-4 py-3">
                  <p class="font-mono text-[0.58rem] font-semibold text-black/35 uppercase tracking-wider mb-1">
                    Steps
                  </p>
                  <p class="font-mono text-[1.1rem] font-bold text-black tabular-nums">
                    {length(@workflow.nodes || [])}
                  </p>
                </div>
              </div>
              <%!-- Last run --%>
              <% last_run = List.first(@runs) %>
              <div class="px-4 py-3">
                <p class="font-mono text-[0.58rem] font-semibold text-black/35 uppercase tracking-wider mb-1">
                  Last Run
                </p>
                <p class="font-mono text-[0.75rem] text-black/70">
                  {if last_run, do: format_datetime_seconds(last_run.started_at), else: "—"}
                </p>
              </div>
              <%!-- ID --%>
              <div class="px-4 py-3">
                <p class="font-mono text-[0.58rem] font-semibold text-black/35 uppercase tracking-wider mb-1.5">
                  ID
                </p>
                <p class="font-mono text-[0.68rem] text-black/70 break-all leading-relaxed select-all">
                  {@workflow.id}
                </p>
              </div>
              <%!-- Triggers --%>
              <div class="px-4 py-3">
                <p class="font-mono text-[0.58rem] font-semibold text-black/35 uppercase tracking-wider mb-2">
                  Triggers
                </p>
                <div class="space-y-2">
                  <div :for={trigger <- @triggers} class="flex items-start gap-2">
                    <.trigger_icon trigger={trigger} workflow_id={@workflow.id} />
                    <div class="min-w-0">
                      <span class={[
                        "font-mono text-[0.75rem] truncate block",
                        if(trigger.enabled, do: "text-black/70", else: "text-black/30 line-through")
                      ]}>
                        {String.replace_prefix(trigger.event_name, "engine:", "")}
                      </span>
                      <span
                        :if={
                          trigger.trigger_type == "cron" and trigger.enabled and
                            not is_nil(trigger.cron_schedule)
                        }
                        id={"cron-cd-#{trigger.id}"}
                        phx-hook="CronCountdown"
                        data-next-at={next_cron_run_unix(trigger.cron_schedule)}
                        class="font-mono text-[0.65rem] text-black/40"
                      ></span>
                    </div>
                  </div>
                  <p :if={@triggers == []} class="font-mono text-[0.72rem] text-black/30 italic">
                    None configured
                  </p>
                </div>
              </div>
            </div>
          </div>

          <%!-- DAG column --%>
          <div class="flex-1 min-w-0">
            <p class="font-mono text-[0.7rem] font-semibold text-black/50 uppercase tracking-wider mb-3">
              Flow
            </p>
            <div
              class="bg-white rounded-xl border border-black/[0.08] p-5 min-h-[480px]"
              style="background-image: linear-gradient(#21dfff 0.5px, transparent 0.5px), linear-gradient(90deg, #e3e3e3 0.5px, transparent 0.5px); background-size: 20px 20px;"
            >
              <.workflow_dag
                nodes={@workflow.nodes}
                edges={@workflow.edges}
                agents_by_id={@agents_by_id}
              />
            </div>
          </div>
        </div>

        <%!-- Runs table --%>
        <div>
          <div class="flex items-center justify-between mb-3">
            <p class="font-mono text-[0.7rem] font-semibold text-black/50 uppercase tracking-wider">
              Runs ({@runs_total})
            </p>
            <div class="flex items-center gap-1">
              <span class="font-mono text-[0.68rem] text-black/35 mr-1">Show</span>
              <button
                :for={n <- @per_page_options}
                phx-click="set_per_page"
                phx-value-limit={n}
                class={[
                  "font-mono text-[0.72rem] px-2.5 py-1 rounded-md border transition-colors",
                  if(@per_page == n,
                    do: "bg-black text-white border-black",
                    else: "border-black/15 text-black/50 hover:bg-black/5"
                  )
                ]}
              >
                {n}
              </button>
            </div>
          </div>

          <DSTable.table id="workflow-runs-table">
            <:head>
              <.table_head_row>
                <.table_cell element={:th}>
                  <.table_text label="Status" tone={:tertiary} />
                </.table_cell>
                <.table_cell element={:th}>
                  <.table_text label="Started" tone={:tertiary} />
                </.table_cell>
                <.table_cell element={:th}>
                  <.table_text label="Duration" tone={:tertiary} />
                </.table_cell>
                <.table_cell element={:th} align={:right} width="w-24" />
              </.table_head_row>
            </:head>
            <:body>
              <.table_empty :if={@runs == []} colspan={4}>
                No runs yet.
              </.table_empty>
              <.table_row
                :for={run <- @runs}
                id={"workflow-run-row-#{run.id}"}
                navigate={~p"/bo/workflows/#{@workflow.id}/runs/#{run.id}"}
              >
                <.table_cell>
                  <.table_badge status={run.status} pulse={run.status == "running"} />
                </.table_cell>
                <.table_cell>
                  <.table_datetime value={run.started_at} />
                </.table_cell>
                <.table_cell>
                  <.run_duration run={run} />
                </.table_cell>
                <.table_cell align={:right} width="w-24" nowrap>
                  <.table_actions reveal={:hover}>
                    <DSButton.button
                      variant={:secondary}
                      navigate={~p"/bo/workflows/#{@workflow.id}/runs/#{run.id}"}
                    >
                      Check details
                    </DSButton.button>
                  </.table_actions>
                </.table_cell>
              </.table_row>
            </:body>
          </DSTable.table>

          <%!-- Pagination --%>
          <div
            :if={@runs_total > @per_page}
            class="flex items-center justify-between mt-4 font-mono text-[0.82rem] text-black"
          >
            <button
              phx-click="paginate"
              phx-value-page={@page - 1}
              disabled={@page <= 1}
              class="px-3 py-1.5 rounded border border-black/15 text-black hover:bg-black/5 disabled:opacity-30 transition-colors"
            >
              ← Prev
            </button>
            <span class="text-black/60">Page {@page} of {@total_pages}</span>
            <button
              phx-click="paginate"
              phx-value-page={@page + 1}
              disabled={@page >= @total_pages}
              class="px-3 py-1.5 rounded border border-black/15 text-black hover:bg-black/5 disabled:opacity-30 transition-colors"
            >
              Next →
            </button>
          </div>
        </div>
      </div>

      <BOModal.form_dialog
        :if={@edit_modal_open}
        id="edit-workflow-modal"
        title="Edit Workflow"
        cancel_event="cancel_edit"
        max_width_class="zaq-modal--width-lg"
      >
        <form phx-submit="save_edit" class="space-y-4">
          <div>
            <label class="font-mono text-[0.72rem] font-semibold text-black/50 uppercase tracking-wider block mb-1.5">
              Name
            </label>
            <input
              type="text"
              name="name"
              value={@edit_name}
              required
              class="w-full font-mono text-[0.85rem] text-[var(--zaq-color-ink)] px-3 py-2 rounded-lg border border-black/15 bg-white focus:outline-none focus:border-[#03b6d4] transition-colors"
            />
          </div>
          <div>
            <label class="font-mono text-[0.72rem] font-semibold text-black/50 uppercase tracking-wider block mb-1.5">
              Description
            </label>
            <textarea
              name="description"
              rows="3"
              class="w-full font-mono text-[0.85rem] text-[var(--zaq-color-ink)] px-3 py-2 rounded-lg border border-black/15 bg-white focus:outline-none focus:border-[#03b6d4] transition-colors resize-none"
            >{@edit_description}</textarea>
          </div>
          <div class="flex justify-end gap-3 pt-1">
            <button
              type="button"
              phx-click="cancel_edit"
              class="font-mono text-[0.82rem] px-4 py-2 rounded-lg border border-black/15 text-black/60 hover:bg-black/5 transition-colors"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="font-mono text-[0.82rem] font-bold px-5 py-2 rounded-lg bg-[#03b6d4] text-white hover:bg-[#029ab3] transition-all"
            >
              Save
            </button>
          </div>
        </form>
      </BOModal.form_dialog>

      <BOModal.confirm_dialog
        :if={@delete_modal_open}
        id="delete-workflow-modal"
        title={"Delete #{@workflow.name}?"}
        message="This will permanently delete the workflow and all its run history. This action cannot be undone."
        confirm_label="Delete Workflow"
        cancel_event="cancel_delete"
        confirm_event="delete"
      />
    </BOLayout.bo_layout>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp fetch_workflow(id, _socket) do
    event =
      Event.new(
        %{module: Zaq.Engine.Workflows, function: :get_workflow!, args: [id]},
        :engine
      )

    case node_router().dispatch(event).response do
      %Zaq.Engine.Workflows.Workflow{} = workflow -> {:ok, workflow}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp count_runs(workflow_id, _socket) do
    event =
      Event.new(
        %{module: Zaq.Engine.Workflows, function: :count_runs, args: [workflow_id]},
        :engine
      )

    case node_router().dispatch(event).response do
      count when is_integer(count) -> count
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp fetch_triggers(workflow_id, _socket) do
    event =
      Event.new(
        %{
          module: Zaq.Engine.Workflows,
          function: :list_triggers_for_workflow,
          args: [workflow_id]
        },
        :engine
      )

    case node_router().dispatch(event).response do
      triggers when is_list(triggers) -> triggers
      _ -> []
    end
  rescue
    _ -> []
  end

  defp fetch_runs(workflow_id, page, per_page, _socket) do
    offset = (page - 1) * per_page

    event =
      Event.new(
        %{
          module: Zaq.Engine.Workflows,
          function: :list_runs,
          args: [workflow_id, [limit: per_page, offset: offset]]
        },
        :engine
      )

    case node_router().dispatch(event).response do
      runs when is_list(runs) -> runs
      _ -> []
    end
  rescue
    _ -> []
  end

  # Bulk-resolves the `agent_id`s referenced by `type: "agent"` nodes so the
  # DAG can render each run_agent step's configured name/model.
  defp fetch_agents_by_id(nodes, _socket) do
    case extract_agent_ids(nodes) do
      [] ->
        %{}

      agent_ids ->
        event =
          Event.new(
            %{module: Zaq.Agent, function: :get_agents_by_ids, args: [agent_ids]},
            :agent
          )

        case node_router().dispatch(event).response do
          agents when is_map(agents) -> agents
          _ -> %{}
        end
    end
  rescue
    _ -> %{}
  end

  defp toggle_status_label("draft"), do: "Activate"
  defp toggle_status_label("active"), do: "Archive"
  defp toggle_status_label("archived"), do: "Restore"
  defp toggle_status_label(_), do: ""

  defp node_router, do: Application.get_env(:zaq, :node_router, Zaq.NodeRouter)

  # Returns the Unix timestamp (seconds) when the cron schedule next fires.
  # Used as `data-next-at` for the JS CronCountdown hook. Falls back to nil.
  defp next_cron_run_unix(cron_schedule) do
    case CronExpression.parse(cron_schedule) do
      {:ok, expr} ->
        expr
        |> CronExpression.next_at(DateTime.utc_now())
        |> DateTime.to_unix()

      _ ->
        nil
    end
  end
end

defmodule ZaqWeb.Live.BO.AI.WorkflowDetailLive do
  @moduledoc """
  BO page — single workflow view with metadata, triggers, paginated run history,
  and an export action.
  """
  use ZaqWeb, :live_view

  import ZaqWeb.Live.BO.AI.WorkflowComponents

  alias Zaq.{Event, NodeRouter}
  alias ZaqWeb.Components.{BOLayout, BOModal}

  @per_page 20

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case fetch_workflow(id, socket) do
      {:ok, workflow} ->
        total = count_runs(workflow.id, socket)
        runs = fetch_runs(workflow.id, 1, socket)
        triggers = fetch_triggers(workflow.id, socket)

        {:ok,
         assign(socket,
           current_path: "/bo/workflows/#{id}",
           workflow: workflow,
           triggers: triggers,
           runs: runs,
           page: 1,
           per_page: @per_page,
           runs_total: total,
           delete_modal_open: false
         )}

      :error ->
        {:ok, push_navigate(socket, to: ~p"/bo/workflows")}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

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

    case NodeRouter.dispatch(event).response do
      data when is_map(data) ->
        json = Jason.encode!(data, pretty: true)
        filename = "workflow-#{socket.assigns.workflow.id}.json"
        {:noreply, push_event(socket, "download", %{filename: filename, content: json})}

      _ ->
        {:noreply, put_flash(socket, :error, "Export failed.")}
    end
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

    case NodeRouter.dispatch(event).response do
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

    run_event =
      Event.new(
        %{module: Zaq.Engine.Workflows, function: :create_run, args: [workflow, %{}]},
        :engine
      )

    case NodeRouter.dispatch(run_event).response do
      {:ok, run} ->
        start_event =
          Event.new(%{module: Zaq.Engine.Workflows, function: :start_run, args: [run]}, :engine)

        NodeRouter.dispatch(start_event)
        {:noreply, push_navigate(socket, to: ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to create run.")}
    end
  end

  def handle_event("paginate", %{"page" => page_str}, socket) do
    page = String.to_integer(page_str)
    runs = fetch_runs(socket.assigns.workflow.id, page, socket)
    {:noreply, assign(socket, runs: runs, page: page)}
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
      current_path={@current_path}
      features_version={@features_version}
    >
      <div id="workflow-detail" phx-hook="WorkflowExport" class="max-w-5xl mx-auto">
        <%!-- Breadcrumb --%>
        <nav class="font-mono text-[0.75rem] text-black mb-5 flex items-center gap-1.5">
          <.link navigate={~p"/bo/workflows"} class="text-black/50 hover:text-black transition-colors">
            Workflows
          </.link>
          <span class="text-black/30">/</span>
          <span class="text-black font-semibold">{@workflow.name}</span>
        </nav>

        <%!-- Page header --%>
        <div class="flex items-start justify-between mb-6">
          <div>
            <h2 class="font-mono text-[1rem] font-bold text-black">{@workflow.name}</h2>
            <div class="mt-1">
              <.workflow_status_badge status={@workflow.status} />
            </div>
          </div>
          <div class="flex items-center gap-2">
            <button
              phx-click="export"
              class="font-mono text-[0.82rem] font-bold px-5 py-2.5 rounded-xl bg-[#03b6d4] text-white hover:bg-[#029ab3] transition-all"
            >
              Export Workflow
            </button>
            <button
              phx-click="open_delete"
              class="font-mono text-[0.82rem] px-4 py-2 rounded-lg border border-red-200 text-red-500 hover:bg-red-50 transition-colors"
            >
              Delete
            </button>
          </div>
        </div>

        <%!-- Metadata card --%>
        <div class="bg-white rounded-xl border border-black/[0.08] p-5 space-y-3 mb-8">
          <p class="font-mono text-[0.7rem] font-semibold text-black/50 uppercase tracking-wider">
            Details
          </p>
          <BOLayout.config_row
            :if={@workflow.description}
            label="Description"
            value={@workflow.description}
          />
          <BOLayout.config_row label="Status" value={@workflow.status} />
          <BOLayout.config_row label="ID" value={@workflow.id} truncate={true} />

          <%!-- Triggers row --%>
          <div class="flex items-start gap-4 py-1">
            <span class="font-mono text-[0.75rem] text-black/40 w-32 flex-shrink-0">Triggers</span>
            <div class="flex items-center gap-2">
              <.trigger_icon
                :for={trigger <- @triggers}
                trigger={trigger}
                workflow_id={@workflow.id}
              />
              <span :if={@triggers == []} class="font-mono text-[0.75rem] text-black/30">
                No triggers configured
              </span>
            </div>
          </div>
        </div>

        <%!-- DAG --%>
        <div class="mb-8">
          <p class="font-mono text-[0.7rem] font-semibold text-black/50 uppercase tracking-wider mb-3">
            Flow
          </p>
          <div class="bg-white rounded-xl border border-black/[0.08] p-5">
            <.workflow_dag nodes={@workflow.nodes} edges={@workflow.edges} />
          </div>
        </div>

        <%!-- Runs table --%>
        <div>
          <p class="font-mono text-[0.7rem] font-semibold text-black/50 uppercase tracking-wider mb-3">
            Runs ({@runs_total})
          </p>

          <div class="bg-white rounded-xl border border-black/[0.08] overflow-hidden">
            <table class="w-full">
              <thead>
                <tr class="border-b border-black/[0.06] bg-black/[0.02]">
                  <th class="font-mono text-[0.7rem] font-semibold text-black/50 uppercase tracking-wider text-left px-5 py-3">
                    Status
                  </th>
                  <th class="font-mono text-[0.7rem] font-semibold text-black/50 uppercase tracking-wider text-left px-5 py-3">
                    Started
                  </th>
                  <th class="font-mono text-[0.7rem] font-semibold text-black/50 uppercase tracking-wider text-left px-5 py-3">
                    Duration
                  </th>
                  <th class="px-5 py-3"></th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={run <- @runs}
                  class="border-b border-black/[0.04] hover:bg-black/[0.01] transition-colors"
                >
                  <td class="px-5 py-3">
                    <.run_status_badge status={run.status} />
                  </td>
                  <td class="px-5 py-3 font-mono text-[0.82rem] text-black">
                    {format_dt(run.started_at)}
                  </td>
                  <td class="px-5 py-3">
                    <.run_duration run={run} />
                  </td>
                  <td class="px-5 py-3 text-right">
                    <.link
                      navigate={~p"/bo/workflows/#{@workflow.id}/runs/#{run.id}"}
                      class="font-mono text-[0.75rem] text-black/40 hover:text-black transition-colors"
                    >
                      View →
                    </.link>
                  </td>
                </tr>
                <tr :if={@runs == []}>
                  <td
                    colspan="4"
                    class="px-5 py-10 text-center font-mono text-[0.85rem] text-black/40"
                  >
                    No runs yet.
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

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

      <BOModal.confirm_dialog
        :if={@delete_modal_open}
        id="delete-workflow-modal"
        title={
          # {@workflow.name}"?"
          "Delete "
        }
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

    case NodeRouter.dispatch(event).response do
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

    case NodeRouter.dispatch(event).response do
      count when is_integer(count) -> count
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp fetch_triggers(workflow_id, _socket) do
    event =
      Event.new(
        %{module: Zaq.Engine.Workflows, function: :list_triggers, args: [workflow_id]},
        :engine
      )

    case NodeRouter.dispatch(event).response do
      triggers when is_list(triggers) -> triggers
      _ -> []
    end
  rescue
    _ -> []
  end

  defp fetch_runs(workflow_id, page, _socket) do
    offset = (page - 1) * @per_page

    event =
      Event.new(
        %{
          module: Zaq.Engine.Workflows,
          function: :list_runs,
          args: [workflow_id, [limit: @per_page, offset: offset]]
        },
        :engine
      )

    case NodeRouter.dispatch(event).response do
      runs when is_list(runs) -> runs
      _ -> []
    end
  rescue
    _ -> []
  end

  defp format_dt(nil), do: "—"

  defp format_dt(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end
end

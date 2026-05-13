defmodule ZaqWeb.Live.BO.AI.WorkflowDetailLive do
  @moduledoc """
  BO page — single workflow view with metadata, triggers, paginated run history,
  and an export action.
  """
  use ZaqWeb, :live_view

  import ZaqWeb.Live.BO.AI.WorkflowComponents

  alias Zaq.{Event, NodeRouter}
  alias ZaqWeb.Components.BOLayout

  @per_page 20

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case fetch_workflow(id, socket) do
      {:ok, workflow} ->
        total = count_runs(workflow.id, socket)
        runs = fetch_runs(workflow.id, 1, socket)

        {:ok,
         assign(socket,
           current_path: "/bo/workflows/#{id}",
           workflow: workflow,
           runs: runs,
           page: 1,
           per_page: @per_page,
           runs_total: total
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
          <.button phx-click="export" class="font-mono text-[0.82rem]">
            Export Workflow
          </.button>
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

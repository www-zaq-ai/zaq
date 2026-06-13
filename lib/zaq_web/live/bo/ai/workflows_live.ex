defmodule ZaqWeb.Live.BO.AI.WorkflowsLive do
  @moduledoc """
  BO page — list of all workflows with filters, latest run, multi-select delete,
  run counts, and an import action.
  """
  use ZaqWeb, :live_view

  import ZaqWeb.Live.BO.AI.WorkflowComponents

  import ZaqWeb.Live.BO.AI.WorkflowRunHelpers, only: [manual_source_event: 1]

  alias Zaq.Event
  alias ZaqWeb.Components.{BOFileUpload, BOLayout, BOModal}

  @impl true
  def mount(_params, _session, socket) do
    all = load_workflows(socket)

    {:ok,
     socket
     |> assign(
       current_path: "/bo/workflows",
       all_workflows: all,
       workflows: all,
       total_filtered: length(all),
       page: 1,
       per_page: 20,
       filters: %{"name" => "", "status" => "all"},
       selected_ids: MapSet.new(),
       delete_confirm: false,
       import_modal_open: false,
       import_error: nil,
       running: false
     )
     |> allow_upload(:workflow_file,
       accept: ~w(.json application/json text/plain),
       max_entries: 1,
       max_file_size: 1_000_000
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # ── Events ──────────────────────────────────────────────────────

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    socket =
      socket
      |> assign(filters: normalize_filters(filters), page: 1, selected_ids: MapSet.new())
      |> apply_filters()

    {:noreply, socket}
  end

  def handle_event("goto_page", %{"page" => p}, socket) do
    total_pages = ceil(socket.assigns.total_filtered / socket.assigns.per_page)
    page = p |> String.to_integer() |> max(1) |> min(max(total_pages, 1))

    {:noreply, socket |> assign(page: page) |> apply_filters()}
  end

  def handle_event("toggle_select", %{"id" => id}, socket) do
    selected =
      if MapSet.member?(socket.assigns.selected_ids, id),
        do: MapSet.delete(socket.assigns.selected_ids, id),
        else: MapSet.put(socket.assigns.selected_ids, id)

    {:noreply, assign(socket, selected_ids: selected)}
  end

  def handle_event("select_all", _params, socket) do
    ids =
      socket.assigns.workflows
      |> Enum.map(fn {w, _, _, _} -> w.id end)
      |> MapSet.new()

    {:noreply, assign(socket, selected_ids: ids)}
  end

  def handle_event("deselect_all", _params, socket) do
    {:noreply, assign(socket, selected_ids: MapSet.new())}
  end

  def handle_event("confirm_delete_selected", _params, socket) do
    {:noreply, assign(socket, delete_confirm: true)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, delete_confirm: false)}
  end

  def handle_event("delete_selected", _params, socket) do
    ids = socket.assigns.selected_ids

    Enum.each(ids, fn id ->
      get_event =
        Event.new(%{module: Zaq.Engine.Workflows, function: :get_workflow!, args: [id]}, :engine)

      case node_router().dispatch(get_event).response do
        %Zaq.Engine.Workflows.Workflow{} = wf ->
          del_event =
            Event.new(
              %{module: Zaq.Engine.Workflows, function: :delete_workflow, args: [wf]},
              :engine
            )

          node_router().dispatch(del_event)

        _ ->
          :skip
      end
    end)

    all = load_workflows(socket)
    count = MapSet.size(ids)

    {:noreply,
     socket
     |> assign(
       all_workflows: all,
       selected_ids: MapSet.new(),
       delete_confirm: false
     )
     |> apply_filters()
     |> put_flash(:info, "#{count} workflow#{if count == 1, do: "", else: "s"} deleted.")}
  end

  def handle_event("open_import", _params, socket) do
    {:noreply, assign(socket, import_modal_open: true, import_error: nil)}
  end

  def handle_event("close_import", _params, socket) do
    {:noreply, assign(socket, import_modal_open: false, import_error: nil)}
  end

  def handle_event("validate_import", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel_workflow_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :workflow_file, ref)}
  end

  def handle_event("run_workflow", %{"workflow_id" => workflow_id}, socket) do
    event =
      Event.new(
        %{module: Zaq.Engine.Workflows, function: :get_workflow!, args: [workflow_id]},
        :engine
      )

    case node_router().dispatch(event).response do
      %Zaq.Engine.Workflows.Workflow{} = workflow ->
        run_event =
          Event.new(
            %{
              module: Zaq.Engine.Workflows,
              function: :create_run,
              args: [workflow, manual_source_event(socket.assigns.current_user)]
            },
            :engine
          )

        case node_router().dispatch(run_event).response do
          {:ok, run} ->
            start_event =
              Event.new(
                %{module: Zaq.Engine.Workflows, function: :start_run, args: [run]},
                :engine
              )

            node_router().dispatch(start_event)
            {:noreply, push_navigate(socket, to: ~p"/bo/workflows/#{workflow_id}/runs/#{run.id}")}

          _ ->
            {:noreply, put_flash(socket, :error, "Failed to create run.")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Workflow not found.")}
    end
  end

  def handle_event("import_workflow", _params, socket) do
    upload = socket.assigns.uploads.workflow_file

    entry_errors =
      Enum.flat_map(upload.entries, &upload_errors(upload, &1))

    if entry_errors != [] do
      msg = Enum.map_join(entry_errors, ", ", &Phoenix.Naming.humanize/1)
      {:noreply, assign(socket, import_error: "Upload error: #{msg}")}
    else
      result =
        consume_uploaded_entries(socket, :workflow_file, fn %{path: path}, _entry ->
          parse_upload_entry(path)
        end)

      case result do
        [attrs] when is_map(attrs) -> dispatch_import(attrs, socket)
        [:bad_json] -> {:noreply, assign(socket, import_error: "File is not valid JSON.")}
        [] -> {:noreply, assign(socket, import_error: "No file selected.")}
        _ -> {:noreply, assign(socket, import_error: "Could not read file.")}
      end
    end
  end

  # ── Private helpers ─────────────────────────────────────────────

  defp apply_filters(socket) do
    %{all_workflows: all, filters: filters, page: page, per_page: per_page} = socket.assigns

    filtered =
      all
      |> filter_by_status(filters["status"])
      |> filter_by_search(filters["name"])

    page_items = filtered |> Enum.drop((page - 1) * per_page) |> Enum.take(per_page)

    assign(socket, workflows: page_items, total_filtered: length(filtered))
  end

  defp normalize_filters(filters) do
    %{
      "name" => Map.get(filters, "name", ""),
      "status" => Map.get(filters, "status", "all")
    }
  end

  defp filter_by_status(list, "all"), do: list

  defp filter_by_status(list, status),
    do: Enum.filter(list, fn {w, _, _, _} -> w.status == status end)

  defp filter_by_search(list, ""), do: list

  defp filter_by_search(list, term) do
    lower = String.downcase(term)
    Enum.filter(list, fn {w, _, _, _} -> String.contains?(String.downcase(w.name), lower) end)
  end

  defp parse_upload_entry(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, attrs} <- Jason.decode(raw) do
      {:ok, attrs}
    else
      {:error, %Jason.DecodeError{}} -> {:ok, :bad_json}
      _ -> {:ok, :read_error}
    end
  end

  defp dispatch_import(attrs, socket) do
    event =
      Event.new(
        %{module: Zaq.Engine.Workflows, function: :import_workflow, args: [attrs]},
        :engine
      )

    case node_router().dispatch(event).response do
      {:ok, _workflow} ->
        all = load_workflows(socket)

        {:noreply,
         socket
         |> assign(import_modal_open: false, import_error: nil, all_workflows: all)
         |> apply_filters()
         |> put_flash(:info, "Workflow imported successfully.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, import_error: error_message(cs))}

      _ ->
        {:noreply, assign(socket, import_error: "Import failed. Please try again.")}
    end
  end

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <BOLayout.bo_layout
      current_user={@current_user}
      flash={@flash}
      page_title="Workflows"
      current_path={@current_path}
      features_version={@features_version}
    >
      <div class="space-y-4">
        <%!-- Page header + filters card --%>
        <section class="rounded-xl border border-[#e6e2db] bg-white px-5 py-4">
          <div class="flex items-center justify-between gap-4">
            <div>
              <h1 class="font-mono text-[0.9rem] uppercase tracking-widest text-[#3e3b36]">
                Workflows
              </h1>
              <p class="mt-1 font-mono text-[0.7rem] text-[#8e8a82]">
                Automated multi-step processes triggered by events or schedules.
              </p>
            </div>
            <div class="flex items-center gap-3">
              <.link
                navigate={~p"/bo/triggers"}
                class="rounded-lg border border-[#e6e2db] px-3 py-2 font-mono text-[0.72rem] text-[#3e3b36] hover:border-[#03b6d4] transition-colors"
              >
                Triggers
              </.link>
              <button
                phx-click="open_import"
                class="rounded-lg bg-[#03b6d4] px-3 py-2 font-mono text-[0.72rem] uppercase tracking-wider text-white hover:bg-[#0198b1] transition-colors"
              >
                Import Workflow
              </button>
            </div>
          </div>

          <form id="workflow-filters-form" phx-change="filter" class="mt-4 grid grid-cols-2 gap-3">
            <input
              type="text"
              name="filters[name]"
              value={@filters["name"]}
              placeholder="Filter by name"
              class="rounded-lg border border-[#e6e2db] px-3 py-2 font-mono text-[0.72rem] text-[#3e3b36] outline-none focus:border-[#03b6d4] focus:ring-1 focus:ring-[#03b6d4]"
            />
            <select
              name="filters[status]"
              class="rounded-lg border border-[#e6e2db] px-3 py-2 font-mono text-[0.72rem] text-[#3e3b36] outline-none focus:border-[#03b6d4] focus:ring-1 focus:ring-[#03b6d4]"
            >
              <option value="all" selected={@filters["status"] == "all"}>All statuses</option>
              <option value="active" selected={@filters["status"] == "active"}>Active</option>
              <option value="draft" selected={@filters["status"] == "draft"}>Draft</option>
              <option value="archived" selected={@filters["status"] == "archived"}>Archived</option>
            </select>
          </form>
        </section>

        <%!-- Bulk action bar (visible when rows selected) --%>
        <div
          :if={MapSet.size(@selected_ids) > 0}
          class="flex items-center justify-between px-4 py-2.5 mb-3 rounded-xl bg-black/[0.04] border border-black/[0.08]"
        >
          <span class="font-mono text-[0.78rem] text-black/60">
            {MapSet.size(@selected_ids)} selected
          </span>
          <div class="flex items-center gap-3">
            <button
              phx-click="deselect_all"
              class="font-mono text-[0.75rem] text-black/40 hover:text-black transition-colors"
            >
              Deselect all
            </button>
            <button
              phx-click="confirm_delete_selected"
              class="font-mono text-[0.75rem] font-semibold text-red-500 hover:text-red-600 transition-colors"
            >
              Delete selected
            </button>
          </div>
        </div>

        <%!-- Delete confirmation --%>
        <div
          :if={@delete_confirm}
          class="flex items-center justify-between px-4 py-3 mb-3 rounded-xl bg-red-50 border border-red-200"
        >
          <p class="font-mono text-[0.8rem] text-red-700">
            Permanently delete {MapSet.size(@selected_ids)} workflow{if MapSet.size(@selected_ids) ==
                                                                          1, do: "", else: "s"} and all their run history? This cannot be undone.
          </p>
          <div class="flex items-center gap-3 ml-4 flex-shrink-0">
            <button
              phx-click="cancel_delete"
              class="font-mono text-[0.75rem] text-black/50 hover:text-black transition-colors"
            >
              Cancel
            </button>
            <button
              phx-click="delete_selected"
              class="font-mono text-[0.75rem] font-bold px-3 py-1.5 rounded-lg bg-red-500 text-white hover:bg-red-600 transition-colors"
            >
              Confirm delete
            </button>
          </div>
        </div>

        <%!-- Workflows table --%>
        <div class="bg-white rounded-xl border border-black/[0.08] overflow-hidden">
          <table class="w-full">
            <thead>
              <tr class="border-b border-black/[0.06] bg-black/[0.02]">
                <th class="px-4 py-3 w-10">
                  <input
                    type="checkbox"
                    checked={
                      MapSet.size(@selected_ids) > 0 and
                        MapSet.size(@selected_ids) == length(@workflows)
                    }
                    phx-click={
                      if MapSet.size(@selected_ids) == length(@workflows),
                        do: "deselect_all",
                        else: "select_all"
                    }
                    class="rounded border-black/20 cursor-pointer"
                  />
                </th>
                <th class="font-mono text-[0.7rem] font-semibold text-black/50 uppercase tracking-wider text-left px-4 py-3">
                  Name
                </th>
                <th class="font-mono text-[0.7rem] font-semibold text-black/50 uppercase tracking-wider text-left px-4 py-3">
                  Status
                </th>
                <th class="font-mono text-[0.7rem] font-semibold text-black/50 uppercase tracking-wider text-left px-4 py-3">
                  Latest Run
                </th>
                <th class="font-mono text-[0.7rem] font-semibold text-black/50 uppercase tracking-wider text-left px-4 py-3">
                  Triggers
                </th>
                <th class="font-mono text-[0.7rem] font-semibold text-black/50 uppercase tracking-wider text-left px-4 py-3">
                  Runs
                </th>
                <th class="px-4 py-3"></th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={{workflow, count, triggers, latest_run} <- @workflows}
                class={[
                  "border-b border-black/[0.04] transition-colors",
                  if(MapSet.member?(@selected_ids, workflow.id),
                    do: "bg-[var(--zaq-color-accent-soft)]",
                    else: "hover:bg-black/[0.01]"
                  )
                ]}
              >
                <td class="px-4 py-4">
                  <input
                    type="checkbox"
                    checked={MapSet.member?(@selected_ids, workflow.id)}
                    phx-click="toggle_select"
                    phx-value-id={workflow.id}
                    class="rounded border-black/20 cursor-pointer"
                  />
                </td>
                <td class="px-4 py-4">
                  <.link
                    navigate={~p"/bo/workflows/#{workflow.id}"}
                    class="font-mono text-[0.85rem] font-semibold text-[var(--zaq-color-accent)] hover:underline"
                  >
                    {workflow.name}
                  </.link>
                  <p :if={workflow.description} class="font-mono text-[0.72rem] text-black/50 mt-0.5">
                    {workflow.description}
                  </p>
                </td>
                <td class="px-4 py-4">
                  <.workflow_status_badge status={workflow.status} />
                </td>
                <td class="px-4 py-4">
                  <div :if={latest_run} class="flex flex-col gap-0.5">
                    <.run_status_badge status={latest_run.status} />
                    <span class="font-mono text-[0.68rem] text-black/30">
                      {format_run_time(latest_run.inserted_at)}
                    </span>
                  </div>
                  <span :if={!latest_run} class="font-mono text-[0.72rem] text-black/30">—</span>
                </td>
                <td class="px-4 py-4">
                  <div class="flex items-center gap-1.5">
                    <.trigger_icon
                      :for={trigger <- triggers}
                      trigger={trigger}
                      workflow_id={workflow.id}
                    />
                    <span :if={triggers == []} class="font-mono text-[0.72rem] text-black/30">—</span>
                  </div>
                </td>
                <td class="px-4 py-4">
                  <span class="font-mono text-[0.85rem] text-black">{count}</span>
                </td>
                <td class="px-4 py-4 text-right">
                  <div class="flex items-center justify-end gap-3">
                    <button
                      phx-click="run_workflow"
                      phx-value-workflow_id={workflow.id}
                      title="Run workflow manually"
                      class="font-mono text-[0.75rem] text-black/40 hover:text-[var(--zaq-color-accent)] transition-colors"
                    >
                      ▶ Run
                    </button>
                    <.link
                      navigate={~p"/bo/workflows/#{workflow.id}"}
                      class="font-mono text-[0.75rem] text-black/40 hover:text-black transition-colors"
                    >
                      View →
                    </.link>
                  </div>
                </td>
              </tr>
              <tr :if={@workflows == []}>
                <td colspan="7" class="px-5 py-12 text-center font-mono text-[0.85rem] text-black/40">
                  {if @filters["name"] != "" or @filters["status"] != "all",
                    do: "No workflows match your filters.",
                    else: "No workflows yet. Import one to get started."}
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <%!-- Pagination --%>
        <div
          :if={@total_filtered > @per_page}
          class="flex items-center justify-between mt-4 px-1"
        >
          <span class="font-mono text-[0.72rem] text-black/40">
            {(@page - 1) * @per_page + 1}–{min(@page * @per_page, @total_filtered)} of {@total_filtered}
          </span>
          <div class="flex items-center gap-1">
            <button
              phx-click="goto_page"
              phx-value-page={@page - 1}
              disabled={@page == 1}
              class="font-mono text-[0.75rem] px-3 py-1.5 rounded-lg border border-black/[0.10] text-black/50 hover:text-black hover:border-black/20 disabled:opacity-30 disabled:cursor-not-allowed transition-colors"
            >
              ← Prev
            </button>
            <%= for p <- page_window(@page, ceil(@total_filtered / @per_page)) do %>
              <%= if p == :gap do %>
                <span class="font-mono text-[0.75rem] px-2 text-black/30">…</span>
              <% else %>
                <button
                  phx-click="goto_page"
                  phx-value-page={p}
                  class={[
                    "font-mono text-[0.75rem] px-3 py-1.5 rounded-lg border transition-colors",
                    if(@page == p,
                      do: "bg-black text-white border-black",
                      else: "border-black/[0.10] text-black/50 hover:text-black hover:border-black/20"
                    )
                  ]}
                >
                  {p}
                </button>
              <% end %>
            <% end %>
            <button
              phx-click="goto_page"
              phx-value-page={@page + 1}
              disabled={@page >= ceil(@total_filtered / @per_page)}
              class="font-mono text-[0.75rem] px-3 py-1.5 rounded-lg border border-black/[0.10] text-black/50 hover:text-black hover:border-black/20 disabled:opacity-30 disabled:cursor-not-allowed transition-colors"
            >
              Next →
            </button>
          </div>
        </div>
      </div>
      <%!-- space-y-4 wrapper --%>

      <%!-- Import modal --%>
      <BOModal.form_dialog
        :if={@import_modal_open}
        id="import-modal"
        title="Import Workflow"
        cancel_event="close_import"
      >
        <form phx-submit="import_workflow" phx-change="validate_import" class="space-y-4">
          <p class="font-mono text-[0.82rem] text-black">
            Upload a <code class="text-black/70">.json</code> workflow export file.
          </p>

          <BOFileUpload.drop_zone
            upload={@uploads.workflow_file}
            id="workflow-import-drop-zone"
            accept_label=".json"
          />

          <div
            :for={entry <- @uploads.workflow_file.entries}
            class="flex items-center justify-between px-3 py-2 rounded-lg bg-black/[0.02] border border-black/10"
          >
            <span class="font-mono text-[0.8rem] text-[var(--zaq-color-ink)] truncate">
              {entry.client_name}
            </span>
            <button
              type="button"
              phx-click="cancel_workflow_upload"
              phx-value-ref={entry.ref}
              class="ml-3 flex-shrink-0 font-mono text-[0.9rem] text-black/30 hover:text-red-400 transition-colors"
              aria-label="Remove"
            >
              &times;
            </button>
          </div>

          <%= for entry <- @uploads.workflow_file.entries,
                  err <- upload_errors(@uploads.workflow_file, entry) do %>
            <p class="font-mono text-[0.72rem] text-red-500">
              {entry.client_name}: {upload_error_label(err)}
            </p>
          <% end %>

          <p
            :if={@import_error}
            class="font-mono text-[0.72rem] text-red-500 bg-red-50 rounded px-3 py-2"
          >
            {@import_error}
          </p>

          <div class="flex justify-end gap-3 pt-2">
            <button
              type="button"
              phx-click="close_import"
              class="font-mono text-[0.82rem] text-[var(--zaq-color-ink)] px-4 py-2 rounded-lg border border-black/15 hover:bg-black/5 transition-colors"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="font-mono text-[0.82rem] font-bold px-5 py-2.5 rounded-xl bg-[#03b6d4] text-white hover:bg-[#029ab3] transition-all"
            >
              Import
            </button>
          </div>
        </form>
      </BOModal.form_dialog>
    </BOLayout.bo_layout>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp load_workflows(_socket) do
    event =
      Event.new(
        %{
          module: Zaq.Engine.Workflows,
          function: :list_workflows_with_details,
          args: []
        },
        :engine
      )

    case node_router().dispatch(event).response do
      workflows when is_list(workflows) -> workflows
      _ -> []
    end
  rescue
    _ -> []
  end

  defp format_run_time(nil), do: ""

  defp format_run_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  defp node_router, do: Application.get_env(:zaq, :node_router, Zaq.NodeRouter)

  defp upload_error_label(:too_large), do: "file exceeds size limit"
  defp upload_error_label(:not_accepted), do: "file type not accepted"
  defp upload_error_label(:too_many_files), do: "too many files"
  defp upload_error_label(_), do: "upload failed"

  defp page_window(_current, total) when total <= 7, do: Enum.to_list(1..total)

  defp page_window(current, total) do
    cond do
      current <= 4 -> Enum.to_list(1..5) ++ [:gap, total]
      current >= total - 3 -> [1, :gap] ++ Enum.to_list((total - 4)..total)
      true -> [1, :gap] ++ Enum.to_list((current - 1)..(current + 1)) ++ [:gap, total]
    end
  end

  defp error_message(%Ecto.Changeset{} = cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
  end
end

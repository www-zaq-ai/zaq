defmodule ZaqWeb.Live.BO.AI.WorkflowsLive do
  @moduledoc """
  BO page — list of all workflows with run counts and an import action.
  """
  use ZaqWeb, :live_view

  import ZaqWeb.Live.BO.AI.WorkflowComponents

  alias Zaq.{Event, NodeRouter}
  alias ZaqWeb.Components.{BOLayout, BOModal}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       current_path: "/bo/workflows",
       workflows: load_workflows(socket),
       import_modal_open: false,
       import_error: nil
     )
     |> allow_upload(:workflow_file,
       accept: ~w(.json),
       max_entries: 1,
       max_file_size: 1_000_000
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # ── Events ──────────────────────────────────────────────────────

  @impl true
  def handle_event("open_import", _params, socket) do
    {:noreply, assign(socket, import_modal_open: true, import_error: nil)}
  end

  def handle_event("close_import", _params, socket) do
    {:noreply, assign(socket, import_modal_open: false, import_error: nil)}
  end

  def handle_event("import_workflow", _params, socket) do
    result =
      consume_uploaded_entries(socket, :workflow_file, fn %{path: path}, _entry ->
        with {:ok, raw} <- File.read(path),
             {:ok, attrs} <- Jason.decode(raw) do
          {:ok, attrs}
        else
          _ -> {:ok, :invalid}
        end
      end)

    case result do
      [attrs] when is_map(attrs) ->
        event =
          Event.new(
            %{module: Zaq.Engine.Workflows, function: :import_workflow, args: [attrs]},
            :engine
          )

        case NodeRouter.dispatch(event).response do
          {:ok, _workflow} ->
            {:noreply,
             socket
             |> assign(import_modal_open: false, import_error: nil)
             |> assign(workflows: load_workflows(socket))
             |> put_flash(:info, "Workflow imported successfully.")}

          {:error, %Ecto.Changeset{} = cs} ->
            {:noreply, assign(socket, import_error: error_message(cs))}

          {:error, _reason} ->
            {:noreply, assign(socket, import_error: "Import failed. Please try again.")}
        end

      _ ->
        {:noreply, assign(socket, import_error: "Invalid JSON file.")}
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
      <div class="max-w-5xl mx-auto">
        <%!-- Page header --%>
        <div class="flex items-center justify-between mb-6">
          <div>
            <h2 class="font-mono text-[1rem] font-bold text-black">Workflows</h2>
            <p class="font-mono text-[0.75rem] text-black/50 mt-0.5">
              Automated multi-step processes triggered by events or schedules.
            </p>
          </div>
          <.button phx-click="open_import" class="font-mono text-[0.82rem]">
            Import Workflow
          </.button>
        </div>

        <%!-- Workflows table --%>
        <div class="bg-white rounded-xl border border-black/[0.08] overflow-hidden">
          <table class="w-full">
            <thead>
              <tr class="border-b border-black/[0.06] bg-black/[0.02]">
                <th class="font-mono text-[0.7rem] font-semibold text-black/50 uppercase tracking-wider text-left px-5 py-3">
                  Name
                </th>
                <th class="font-mono text-[0.7rem] font-semibold text-black/50 uppercase tracking-wider text-left px-5 py-3">
                  Status
                </th>
                <th class="font-mono text-[0.7rem] font-semibold text-black/50 uppercase tracking-wider text-left px-5 py-3">
                  Runs
                </th>
                <th class="px-5 py-3"></th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={{workflow, count} <- @workflows}
                class="border-b border-black/[0.04] hover:bg-black/[0.01] transition-colors"
              >
                <td class="px-5 py-4">
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
                <td class="px-5 py-4">
                  <.workflow_status_badge status={workflow.status} />
                </td>
                <td class="px-5 py-4">
                  <span class="font-mono text-[0.85rem] text-black">{count}</span>
                </td>
                <td class="px-5 py-4 text-right">
                  <.link
                    navigate={~p"/bo/workflows/#{workflow.id}"}
                    class="font-mono text-[0.75rem] text-black/40 hover:text-black transition-colors"
                  >
                    View →
                  </.link>
                </td>
              </tr>
              <tr :if={@workflows == []}>
                <td colspan="4" class="px-5 py-12 text-center font-mono text-[0.85rem] text-black/40">
                  No workflows yet. Import one to get started.
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <%!-- Import modal --%>
      <BOModal.form_dialog
        :if={@import_modal_open}
        id="import-modal"
        title="Import Workflow"
        cancel_event="close_import"
      >
        <form phx-submit="import_workflow" class="space-y-4">
          <p class="font-mono text-[0.82rem] text-black">
            Upload a <code class="text-black/70">.json</code> workflow export file.
          </p>

          <div class="border-2 border-dashed border-black/20 rounded-lg p-6 text-center">
            <.live_file_input
              upload={@uploads.workflow_file}
              class="font-mono text-[0.82rem] text-black"
            />
          </div>

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
              class="font-mono text-[0.82rem] px-4 py-2 rounded-lg border border-black/15 hover:bg-black/5 transition-colors"
            >
              Cancel
            </button>
            <.button type="submit" class="font-mono text-[0.82rem]">
              Import
            </.button>
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
        %{module: Zaq.Engine.Workflows, function: :list_workflows_with_run_counts, args: []},
        :engine
      )

    case NodeRouter.dispatch(event).response do
      workflows when is_list(workflows) -> workflows
      _ -> []
    end
  rescue
    _ -> []
  end

  defp error_message(%Ecto.Changeset{} = cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
  end
end

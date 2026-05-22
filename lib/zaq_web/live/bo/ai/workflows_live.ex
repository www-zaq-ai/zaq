defmodule ZaqWeb.Live.BO.AI.WorkflowsLive do
  @moduledoc """
  BO page — list of all workflows with run counts and an import action.
  """
  use ZaqWeb, :live_view

  import ZaqWeb.Live.BO.AI.WorkflowComponents

  alias Zaq.{Event, NodeRouter}
  alias ZaqWeb.Components.{BOFileUpload, BOLayout, BOModal}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       current_path: "/bo/workflows",
       workflows: load_workflows(socket),
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

    case NodeRouter.dispatch(event).response do
      %Zaq.Engine.Workflows.Workflow{} = workflow ->
        run_event =
          Event.new(
            %{module: Zaq.Engine.Workflows, function: :create_run, args: [workflow, %{}]},
            :engine
          )

        case NodeRouter.dispatch(run_event).response do
          {:ok, run} ->
            start_event =
              Event.new(
                %{module: Zaq.Engine.Workflows, function: :start_run, args: [run]},
                :engine
              )

            NodeRouter.dispatch(start_event)
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

    case NodeRouter.dispatch(event).response do
      {:ok, _workflow} ->
        {:noreply,
         socket
         |> assign(import_modal_open: false, import_error: nil)
         |> assign(workflows: load_workflows(socket))
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
      <div>
        <%!-- Page header --%>
        <div class="flex items-center justify-between mb-6">
          <div>
            <h2 class="font-mono text-[1rem] font-bold text-black">Workflows</h2>
            <p class="font-mono text-[0.75rem] text-black/50 mt-0.5">
              Automated multi-step processes triggered by events or schedules.
            </p>
          </div>
          <button
            phx-click="open_import"
            class="font-mono text-[0.82rem] font-bold px-5 py-2.5 rounded-xl bg-[#03b6d4] text-white hover:bg-[#029ab3] transition-all"
          >
            Import Workflow
          </button>
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
                  Triggers
                </th>
                <th class="font-mono text-[0.7rem] font-semibold text-black/50 uppercase tracking-wider text-left px-5 py-3">
                  Runs
                </th>
                <th class="px-5 py-3"></th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={{workflow, count, triggers} <- @workflows}
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
                  <div class="flex items-center gap-1.5">
                    <.trigger_icon
                      :for={trigger <- triggers}
                      trigger={trigger}
                      workflow_id={workflow.id}
                    />
                    <span :if={triggers == []} class="font-mono text-[0.72rem] text-black/30">—</span>
                  </div>
                </td>
                <td class="px-5 py-4">
                  <span class="font-mono text-[0.85rem] text-black">{count}</span>
                </td>
                <td class="px-5 py-4 text-right">
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
                <td colspan="5" class="px-5 py-12 text-center font-mono text-[0.85rem] text-black/40">
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
          function: :list_workflows_with_run_counts_and_triggers,
          args: []
        },
        :engine
      )

    case NodeRouter.dispatch(event).response do
      workflows when is_list(workflows) -> workflows
      _ -> []
    end
  rescue
    _ -> []
  end

  defp upload_error_label(:too_large), do: "file exceeds size limit"
  defp upload_error_label(:not_accepted), do: "file type not accepted"
  defp upload_error_label(:too_many_files), do: "too many files"
  defp upload_error_label(_), do: "upload failed"

  defp error_message(%Ecto.Changeset{} = cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
  end
end

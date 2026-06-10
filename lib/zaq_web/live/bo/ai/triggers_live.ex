defmodule ZaqWeb.Live.BO.AI.TriggersLive do
  @moduledoc """
  BO page — list of all triggers with event picker, workflow assignment,
  recent runs, and full CRUD.
  """
  use ZaqWeb, :live_view

  import ZaqWeb.Live.BO.AI.TriggerComponents

  alias Zaq.Engine.EventRegistry
  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Trigger
  alias Zaq.{Event, NodeRouter}
  alias ZaqWeb.Components.{BOLayout, BOModal}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       current_path: "/bo/triggers",
       page_title: "Triggers",
       modal: :none,
       form: nil,
       assign_trigger_id: nil
     )
     |> load_page_data()}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # ── Events ────────────────────────────────────────────────────────

  @impl true
  def handle_event("open_create", _params, socket) do
    {:noreply,
     socket
     |> assign(modal: :create)
     |> assign(form: build_form(%Trigger{}))}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, modal: :none, form: nil, assign_trigger_id: nil)}
  end

  def handle_event("set_event_name", %{"name" => name}, socket) do
    current_params = Map.get(socket.assigns.form || %{}, :params, %{})

    form =
      %Trigger{}
      |> Trigger.changeset(atomize(Map.put(current_params, "event_name", name)))
      |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("validate", %{"trigger" => params}, socket) do
    form =
      %Trigger{}
      |> Trigger.changeset(atomize(normalize_trigger_params(params)))
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("create_trigger", %{"trigger" => params}, socket) do
    attrs = params |> normalize_trigger_params() |> atomize()

    result =
      Event.new(%{action: "create", attrs: attrs}, :engine, opts: [action: :trigger])
      |> NodeRouter.dispatch()
      |> Map.get(:response)

    case result do
      {:ok, _trigger} ->
        {:noreply,
         socket
         |> assign(modal: :none, form: nil)
         |> load_page_data()
         |> put_flash(:info, "Trigger created.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, form: to_form(Map.put(cs, :action, :insert)))}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to create trigger.")}
    end
  end

  def handle_event("open_edit", %{"trigger_id" => id}, socket) do
    trigger = Enum.find_value(socket.assigns.triggers, fn {t, _} -> if t.id == id, do: t end)

    if trigger do
      {:noreply,
       socket
       |> assign(modal: {:edit, id})
       |> assign(form: build_form(trigger))}
    else
      {:noreply, put_flash(socket, :error, "Trigger not found.")}
    end
  end

  def handle_event("update_trigger", %{"trigger" => params, "trigger_id" => id}, socket) do
    trigger = find_trigger(socket, id)
    attrs = params |> normalize_trigger_params() |> atomize()

    result =
      Event.new(%{action: "update", trigger: trigger, attrs: attrs}, :engine,
        opts: [action: :trigger]
      )
      |> NodeRouter.dispatch()
      |> Map.get(:response)

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(modal: :none, form: nil)
         |> load_page_data()
         |> put_flash(:info, "Trigger updated.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, form: to_form(Map.put(cs, :action, :update)))}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to update trigger.")}
    end
  end

  def handle_event("toggle_enabled", %{"trigger_id" => id}, socket) do
    trigger = find_trigger(socket, id)

    Event.new(
      %{action: "update", trigger: trigger, attrs: %{enabled: !trigger.enabled}},
      :engine,
      opts: [action: :trigger]
    )
    |> NodeRouter.dispatch()

    {:noreply, load_page_data(socket)}
  end

  def handle_event("open_delete", %{"trigger_id" => id}, socket) do
    {:noreply, assign(socket, modal: {:delete, id})}
  end

  def handle_event("confirm_delete", %{"trigger_id" => id}, socket) do
    trigger = find_trigger(socket, id)

    Event.new(%{action: "delete", trigger: trigger}, :engine, opts: [action: :trigger])
    |> NodeRouter.dispatch()

    {:noreply,
     socket
     |> assign(modal: :none)
     |> load_page_data()
     |> put_flash(:info, "Trigger deleted.")}
  end

  def handle_event("open_assign", %{"trigger_id" => id}, socket) do
    {:noreply, assign(socket, modal: {:assign, id}, assign_trigger_id: id)}
  end

  def handle_event("assign_workflow", %{"trigger_id" => id, "workflow_id" => wf_id}, socket) do
    trigger = find_trigger(socket, id)
    workflow = Enum.find(socket.assigns.all_workflows, &(&1.id == wf_id))

    Event.new(%{action: "assign_workflow", trigger: trigger, workflow: workflow}, :engine,
      opts: [action: :trigger]
    )
    |> NodeRouter.dispatch()

    {:noreply,
     socket
     |> assign(modal: :none, assign_trigger_id: nil)
     |> load_page_data()}
  end

  def handle_event("remove_workflow", %{"trigger_id" => id, "workflow_id" => wf_id}, socket) do
    trigger = find_trigger(socket, id)
    workflow = Enum.find(socket.assigns.all_workflows, &(&1.id == wf_id))

    Event.new(%{action: "remove_workflow", trigger: trigger, workflow: workflow}, :engine,
      opts: [action: :trigger]
    )
    |> NodeRouter.dispatch()

    {:noreply, load_page_data(socket)}
  end

  # ── Render ────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <BOLayout.bo_layout
      current_user={@current_user}
      page_title="Triggers"
      current_path={@current_path}
      flash={@flash}
    >
      <.trigger_explainer />

      <%!-- Header --%>
      <div class="flex items-center justify-between mb-6">
        <h2 class="font-mono text-[0.85rem] font-semibold text-[var(--zaq-color-ink)]">
          Triggers ({length(@triggers)})
        </h2>
        <button
          phx-click="open_create"
          class="font-mono text-[0.78rem] font-bold px-4 py-2 rounded-lg bg-[var(--zaq-color-accent)] text-white hover:bg-[var(--zaq-color-accent-hover)] transition-colors"
        >
          + New Trigger
        </button>
      </div>

      <%!-- Empty state --%>
      <div
        :if={@triggers == []}
        class="flex flex-col items-center justify-center py-20 text-center"
      >
        <svg
          class="w-10 h-10 text-black/15 mb-3"
          fill="none"
          stroke="currentColor"
          stroke-width="1.5"
          viewBox="0 0 24 24"
        >
          <path stroke-linecap="round" stroke-linejoin="round" d="M13 2L3 14h9l-1 8 10-12h-9l1-8z" />
        </svg>
        <p class="font-mono text-[0.82rem] text-black/40">No triggers yet</p>
        <p class="font-mono text-[0.72rem] text-black/25 mt-1">
          Create one to start automating workflows from events.
        </p>
      </div>

      <%!-- Trigger cards --%>
      <div class="space-y-4">
        <.trigger_card
          :for={{trigger, enriched} <- @triggers}
          trigger={trigger}
          enriched_workflows={enriched}
        />
      </div>

      <%!-- Create modal --%>
      <BOModal.form_dialog :if={@modal == :create} title="New Trigger" cancel_event="close_modal">
        <form phx-change="validate" phx-submit="create_trigger" class="space-y-4">
          <.trigger_form form={@form} known_events={@known_events} />
          <div class="flex justify-end gap-2 pt-2">
            <button
              type="button"
              phx-click="close_modal"
              class="font-mono text-[0.78rem] px-4 py-2 rounded-lg border border-black/15 text-black/50 hover:bg-black/[0.03]"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="font-mono text-[0.78rem] font-bold px-4 py-2 rounded-lg bg-[var(--zaq-color-accent)] text-white hover:bg-[var(--zaq-color-accent-hover)]"
            >
              Create
            </button>
          </div>
        </form>
      </BOModal.form_dialog>

      <%!-- Edit modal --%>
      <BOModal.form_dialog
        :if={match?({:edit, _}, @modal)}
        title="Edit Trigger"
        cancel_event="close_modal"
      >
        <form
          phx-change="validate"
          phx-submit="update_trigger"
          phx-value-trigger_id={elem(@modal, 1)}
          class="space-y-4"
        >
          <.trigger_form form={@form} known_events={@known_events} />
          <div class="flex justify-end gap-2 pt-2">
            <button
              type="button"
              phx-click="close_modal"
              class="font-mono text-[0.78rem] px-4 py-2 rounded-lg border border-black/15 text-black/50 hover:bg-black/[0.03]"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="font-mono text-[0.78rem] font-bold px-4 py-2 rounded-lg bg-[var(--zaq-color-accent)] text-white hover:bg-[var(--zaq-color-accent-hover)]"
            >
              Save
            </button>
          </div>
        </form>
      </BOModal.form_dialog>

      <%!-- Delete confirmation modal --%>
      <BOModal.form_dialog
        :if={match?({:delete, _}, @modal)}
        title="Delete Trigger"
        cancel_event="close_modal"
      >
        <p class="font-mono text-[0.82rem] text-[var(--zaq-color-ink)] mb-5">
          Are you sure you want to delete this trigger? This cannot be undone.
        </p>
        <div class="flex justify-end gap-2">
          <button
            phx-click="close_modal"
            class="font-mono text-[0.78rem] px-4 py-2 rounded-lg border border-black/15 text-black/50 hover:bg-black/[0.03]"
          >
            Cancel
          </button>
          <button
            phx-click="confirm_delete"
            phx-value-trigger_id={elem(@modal, 1)}
            class="font-mono text-[0.78rem] font-bold px-4 py-2 rounded-lg bg-red-500 text-white hover:bg-red-600"
          >
            Delete
          </button>
        </div>
      </BOModal.form_dialog>

      <%!-- Assign workflow modal --%>
      <BOModal.form_dialog
        :if={match?({:assign, _}, @modal)}
        title="Connect Workflow"
        cancel_event="close_modal"
      >
        <div class="space-y-2">
          <%= for wf <- assignable_workflows(@triggers, @assign_trigger_id, @all_workflows) do %>
            <button
              phx-click="assign_workflow"
              phx-value-trigger_id={@assign_trigger_id}
              phx-value-workflow_id={wf.id}
              class="w-full text-left px-4 py-3 rounded-lg border border-black/10 hover:border-[var(--zaq-color-accent)] hover:bg-[var(--zaq-color-accent-soft)] transition-colors"
            >
              <p class="font-mono text-[0.82rem] font-semibold text-[var(--zaq-color-ink)]">
                {wf.name}
              </p>
              <p :if={wf.description} class="font-mono text-[0.72rem] text-black/40 mt-0.5">
                {wf.description}
              </p>
            </button>
          <% end %>
          <p
            :if={assignable_workflows(@triggers, @assign_trigger_id, @all_workflows) == []}
            class="font-mono text-[0.78rem] text-black/40 py-4 text-center"
          >
            All workflows already connected.
          </p>
        </div>
      </BOModal.form_dialog>
    </BOLayout.bo_layout>
    """
  end

  # ── Helpers ───────────────────────────────────────────────────────

  defp load_page_data(socket) do
    triggers =
      Event.new(%{action: "list_with_runs"}, :engine, opts: [action: :trigger])
      |> NodeRouter.dispatch()
      |> Map.get(:response, [])

    all_workflows =
      Event.new(%{action: "list_workflows"}, :engine, opts: [action: :trigger])
      |> NodeRouter.dispatch()
      |> Map.get(:response, [])

    known_events =
      try do
        EventRegistry.list_events() |> Map.keys() |> Enum.sort()
      rescue
        _ -> []
      end

    assign(socket, triggers: triggers, all_workflows: all_workflows, known_events: known_events)
  end

  defp build_form(%Trigger{} = trigger) do
    trigger |> Trigger.changeset(%{}) |> to_form()
  end

  defp find_trigger(socket, id) do
    Enum.find_value(socket.assigns.triggers, fn {t, _} -> if t.id == id, do: t end) ||
      Workflows.get_trigger!(id)
  end

  defp atomize(params) do
    Map.new(params, fn {k, v} -> {String.to_existing_atom(k), v} end)
  rescue
    _ -> params
  end

  # Resolves the cron_schedule from the cron_preset UI param and removes
  # cron_preset (not a schema field) before the params reach the changeset.
  defp normalize_trigger_params(params) do
    cron_preset = Map.get(params, "cron_preset")
    trigger_type = Map.get(params, "trigger_type", "event")

    params =
      cond do
        trigger_type != "cron" ->
          Map.put(params, "cron_schedule", nil)

        cron_preset not in [nil, "custom"] ->
          Map.put(params, "cron_schedule", cron_preset)

        true ->
          params
      end

    Map.delete(params, "cron_preset")
  end

  defp assignable_workflows(triggers, trigger_id, all_workflows) do
    already =
      Enum.find_value(triggers, [], fn {t, enriched} ->
        if t.id == trigger_id, do: Enum.map(enriched, & &1.workflow.id)
      end)

    Enum.reject(all_workflows, &(&1.id in already or &1.status == "archived"))
  end
end

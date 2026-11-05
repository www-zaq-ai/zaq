defmodule ZaqWeb.Components.LabelEditor do
  @moduledoc """
  Shared document/chunk modal state and event consumer.

  A LiveComponent keeps staging and versions identical across parent surfaces.
  Parents handle close_label_editor and {:resource_labels_saved, resource}; failures
  retain staging until the user explicitly reloads. All persistence uses Events.
  """
  use ZaqWeb, :live_component
  alias ZaqWeb.Components.DesignSystem.LabelEditor, as: Editor
  alias ZaqWeb.Live.BO.LabelEvents

  @impl true
  def mount(socket),
    do:
      {:ok,
       assign(socket,
         resource: nil,
         labels: [],
         selected: MapSet.new(),
         values: %{},
         suggestions: %{},
         editable: false,
         query: "",
         error: nil
       )}

  @impl true
  def update(assigns, socket) do
    changed? = socket.assigns.resource != assigns.resource
    socket = assign(socket, assigns)
    {:ok, if(changed?, do: load(socket), else: socket)}
  end

  @impl true
  def handle_event("toggle_label", %{"id" => id}, socket) do
    label = Enum.find(socket.assigns.labels, &(to_string(&1.id) == id))

    if socket.assigns.editable and label do
      selected = socket.assigns.selected

      selected =
        if MapSet.member?(selected, label.id),
          do: MapSet.delete(selected, label.id),
          else: MapSet.put(selected, label.id)

      {:noreply, assign(socket, selected: selected, query: "")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("change_label_value", %{"label_id" => id, "value" => value}, socket) do
    case editable_label(socket, id) do
      nil ->
        {:noreply, socket}

      label ->
        socket =
          assign(socket,
            values: Map.put(socket.assigns.values, label.id, String.slice(value, 0, 200))
          )

        {:noreply, socket}
    end
  end

  def handle_event("search_label_values", %{"label_id" => id, "query" => query}, socket) do
    case editable_label(socket, id) do
      nil -> {:noreply, socket}
      label -> {:noreply, suggest_values(socket, label.id, query)}
    end
  end

  def handle_event("create_label_value", %{"label_id" => id, "name" => value}, socket) do
    handle_event("change_label_value", %{"label_id" => id, "value" => value}, socket)
  end

  def handle_event("reload_labels", _, socket), do: {:noreply, load(socket)}

  def handle_event("search_labels", %{"query" => query}, socket),
    do: {:noreply, assign(socket, query: String.slice(query, 0, 200))}

  def handle_event("save_labels", _, %{assigns: %{editable: false}} = socket),
    do: {:noreply, socket}

  def handle_event("save_labels", _, socket) do
    edits =
      socket.assigns.labels
      |> Enum.filter(&assignment_changed?(&1, socket.assigns))
      |> Enum.map(
        &%{
          label_id: &1.id,
          value: Map.get(socket.assigns.values, &1.id),
          expected_version: &1.expected_version,
          operation: if(MapSet.member?(socket.assigns.selected, &1.id), do: "add", else: "remove")
        }
      )

    case LabelEvents.call(socket.assigns.current_user, :edit_resource_labels, %{
           resource: socket.assigns.resource,
           edits: edits
         }) do
      {:ok, _} ->
        send(self(), {:resource_labels_saved, socket.assigns.resource})
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, error: LabelEvents.error_message(reason))}
    end
  end

  defp assignment_changed?(label, assigns) do
    selected? = MapSet.member?(assigns.selected, label.id)

    label.selected != selected? or
      (selected? and (label.value || "") != Map.get(assigns.values, label.id, ""))
  end

  defp editable_label(socket, id) do
    if socket.assigns.editable do
      Enum.find(socket.assigns.labels, fn label ->
        to_string(label.id) == id and MapSet.member?(socket.assigns.selected, label.id)
      end)
    end
  end

  defp suggest_values(socket, label_id, query) do
    case LabelEvents.call(socket.assigns.current_user, :label_value_suggestions, %{
           resource: socket.assigns.resource,
           label_id: label_id,
           query: query
         }) do
      {:ok, values} ->
        assign(socket, suggestions: Map.put(socket.assigns.suggestions, label_id, values))

      {:error, reason} ->
        assign(socket, suggestions: %{}, error: LabelEvents.error_message(reason))
    end
  end

  defp load(socket) do
    case LabelEvents.call(socket.assigns.current_user, :get_resource_labels, %{
           resource: socket.assigns.resource
         }) do
      {:ok, editor} ->
        assign(socket,
          labels: editor.labels,
          values: Map.new(editor.labels, &{&1.id, &1.value || ""}),
          suggestions: %{},
          selected: MapSet.new(for l <- editor.labels, l.selected, do: l.id),
          editable: editor.editable?,
          error: nil
        )

      {:error, reason} ->
        assign(socket,
          labels: [],
          values: %{},
          suggestions: %{},
          selected: MapSet.new(),
          editable: false,
          error: LabelEvents.error_message(reason)
        )
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <Editor.label_editor
        labels={@labels}
        selected={@selected}
        values={@values}
        suggestions={@suggestions}
        editable={@editable}
        error={@error}
        target={@myself}
        query={@query}
      />
    </div>
    """
  end
end

defmodule ZaqWeb.LabelEditorHost do
  @moduledoc false
  use ZaqWeb, :live_view

  def mount(_, session, socket) do
    {:ok,
     assign(socket,
       current_user: session["user"],
       resource: session["resource"],
       open: true,
       saved: false
     )}
  end

  def handle_event("close_label_editor", _, socket), do: {:noreply, assign(socket, open: false)}

  def handle_info({:resource_labels_saved, _}, socket),
    do: {:noreply, assign(socket, open: false, saved: true)}

  def render(assigns) do
    ~H"""
    <div id="label-editor-host">
      <p :if={@saved} id="labels-saved">Saved</p>
      <.live_component
        :if={@open}
        module={ZaqWeb.Components.LabelEditor}
        id="test-label-editor"
        resource={@resource}
        current_user={@current_user}
      />
    </div>
    """
  end
end

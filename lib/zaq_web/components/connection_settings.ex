defmodule ZaqWeb.Components.ConnectionSettings do
  @moduledoc """
  Shared Main and Advanced settings presentation for connection editors.

  Reuses the People selector pattern with native Toggle buttons and pressed state.
  Inactive controls remain mounted for one parent-owned form submission. Parents
  own capability applicability, drafts, validation and persistence.
  """

  use Phoenix.Component

  alias ZaqWeb.Components.DesignSystem.Toggle

  attr :id, :string, required: true
  attr :active_tab, :atom, default: :main
  attr :event, :string, default: "switch_settings_tab"
  attr :errors, :map, default: %{}
  slot :main, required: true

  slot :advanced do
    attr :id, :string, required: true
    attr :label, :string, required: true
  end

  def editor(assigns) do
    assigns =
      assign(assigns, :choices, [
        %{value: "main", label: choice_label("Main", assigns.errors[:main])},
        %{value: "advanced", label: choice_label("Advanced settings", assigns.errors[:advanced])}
      ])

    ~H"""
    <div id={@id} class="zaq-layout-stack">
      <div :if={@advanced != []} id={@id <> "-selector"} role="group" aria-label="Connection settings">
        <Toggle.toggle
          value={Atom.to_string(@active_tab)}
          event={@event}
          value_param="tab"
          choices={@choices}
        />
      </div>
      <section
        id={@id <> "-panel-main"}
        aria-label="Main settings"
        hidden={@advanced != [] && @active_tab != :main}
      >
        <div class="zaq-layout-stack">{render_slot(@main)}</div>
      </section>
      <section
        :if={@advanced != []}
        id={@id <> "-panel-advanced"}
        aria-label="Advanced settings"
        hidden={@active_tab != :advanced}
      >
        <div class="zaq-layout-stack">
          <section :for={section <- @advanced} id={section.id} class="zaq-layout-stack">
            <h3 class="zaq-text-h3">{section.label}</h3>
            {render_slot(section)}
          </section>
        </div>
      </section>
    </div>
    """
  end

  @doc "Selects Main errors first, then Advanced errors, retaining the current selection otherwise."
  def tab_for_errors(active_tab, errors) do
    cond do
      errors[:main] -> :main
      errors[:advanced] -> :advanced
      true -> active_tab
    end
  end

  @doc "Handles presentation-only switching for a parent-owned settings form."
  def switch_settings_tab(%{"tab" => tab}, socket) when tab in ["main", "advanced"] do
    {:noreply, assign(socket, :settings_tab, if(tab == "main", do: :main, else: :advanced))}
  end

  defp choice_label(label, true), do: label <> " — Errors"
  defp choice_label(label, _), do: label
end

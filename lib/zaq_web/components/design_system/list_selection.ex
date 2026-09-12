defmodule ZaqWeb.Components.DesignSystem.ListSelection do
  @moduledoc """
  Reusable page-first selection controls. The parent owns selection, filters,
  totals and events; this component never queries data or performs bulk actions.
  Supply domain actions through the actions slot.
  """
  use Phoenix.Component

  alias ZaqWeb.Components.DesignSystem.{Button, Checkbox, Table}
  alias ZaqWeb.Helpers.Selection

  attr :id, :string, required: true
  attr :selection, Selection, required: true
  attr :page_ids, :list, required: true
  attr :total_count, :integer, required: true
  attr :page_event, :any, required: true
  attr :all_event, :any, required: true
  attr :clear_event, :any, required: true
  slot :actions

  def list_selection(assigns) do
    assigns =
      assigns
      |> assign(:page_state, Selection.page_state(assigns.selection, assigns.page_ids))
      |> assign(:selected_count, Selection.count(assigns.selection, assigns.total_count))

    ~H"""
    <div id={@id} class="zaq-layout-inline flex-wrap">
      <Checkbox.checkbox
        id={@id <> "-page"}
        label="Select current page"
        checked={@page_state == :all}
        indeterminate={@page_state == :mixed}
        disabled={@page_ids == []}
        phx-click={@page_event}
      />
      <div aria-live="polite" class="zaq-layout-inline flex-wrap">
        <div
          :if={@selected_count > 0 || @selection.mode == :all_matching}
          class="zaq-layout-inline flex-wrap"
        >
          <Table.table_text label={"#{@selected_count} selected"} tone={:secondary} />
          <span :if={@selection.mode == :all_matching} class="zaq-text-body-sm">
            All matching results across pages selected; {MapSet.size(@selection.ids)} excluded.
          </span>
          <Button.button
            id={@id <> "-clear"}
            variant={:ghost}
            phx-click={@clear_event}
          >
            Clear selection
          </Button.button>
        </div>
        <div :if={@selected_count > 0} class="zaq-layout-inline flex-wrap">
          <Button.button
            :if={
              @selection.mode == :explicit && @page_state == :all &&
                @total_count > length(@page_ids)
            }
            id={@id <> "-all"}
            variant={:ghost}
            phx-click={@all_event}
          >
            Select all {@total_count} matching results
          </Button.button>
          {render_slot(@actions)}
        </div>
      </div>
    </div>
    """
  end
end

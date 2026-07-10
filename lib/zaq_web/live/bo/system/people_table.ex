defmodule ZaqWeb.Live.BO.System.PeopleTable do
  @moduledoc """
  BO people master pane — selectable person list table.
  """

  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.StatusDot, only: [status_dot: 1]

  import ZaqWeb.Components.DesignSystem.Table,
    only: [
      table: 1,
      table_badge: 1,
      table_cell: 1,
      table_checkbox: 1,
      table_head_row: 1,
      table_media: 1,
      table_row: 1,
      table_text: 1
    ]

  attr :people, :list, required: true
  attr :selected_people, :any, required: true
  attr :selected_person, :any, default: nil

  def people_table(assigns) do
    ~H"""
    <.table id="people-table" scrollable={true}>
      <:head>
        <.table_head_row>
          <.table_cell element={:th} width="w-10" />
          <.table_cell element={:th}>
            <.table_text label="Name" tone={:tertiary} />
          </.table_cell>
          <.table_cell element={:th}>
            <.table_text label="Status" tone={:tertiary} />
          </.table_cell>
        </.table_head_row>
      </:head>
      <:body>
        <.table_row
          :for={person <- @people}
          id={"person-row-#{person.id}"}
          click="select_person"
          click_values={%{id: person.id}}
          variant={
            if(@selected_person && @selected_person.id == person.id,
              do: :selected,
              else: :default
            )
          }
        >
          <.table_cell width="w-10">
            <.table_checkbox
              checked={MapSet.member?(@selected_people, person.id)}
              phx-click="toggle_person_selection"
              phx-value-id={person.id}
            />
          </.table_cell>
          <.table_cell>
            <.table_media>
              <:icon>
                <span
                  class="zaq-text-h3 grid place-items-center shrink-0"
                  style={
                    "width: var(--zaq-scale-40); height: var(--zaq-scale-40); " <>
                      "border-radius: var(--zaq-scale-8); " <>
                      "background-color: var(--zaq-surface-color-accent); " <>
                      "color: var(--zaq-text-color-body-secondary); " <>
                      "font-weight: var(--zaq-font-weight-semibold);"
                  }
                >
                  {String.first(person.full_name) |> String.upcase()}
                </span>
              </:icon>
              <div class="min-w-0">
                <.table_text label={person.full_name} />
                <.table_text
                  :if={person.role}
                  label={person.role}
                  tone={:tertiary}
                  truncate
                  class="line-clamp-1"
                />
              </div>
            </.table_media>
          </.table_cell>
          <.table_cell>
            <div class="flex items-center gap-2 flex-wrap">
              <.table_badge :if={person.incomplete} status="draft">incomplete</.table_badge>
              <% preferred = List.first(person.channels) %>
              <.table_badge :if={preferred} status="processing">{preferred.platform}</.table_badge>
              <.status_dot status={if(person.status == "active", do: :active, else: :inactive)} />
            </div>
          </.table_cell>
        </.table_row>
      </:body>
    </.table>
    """
  end
end

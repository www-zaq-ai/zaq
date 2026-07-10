defmodule ZaqWeb.Live.BO.System.TeamsTable do
  @moduledoc """
  BO teams master pane — team list table with edit and delete actions.
  """

  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.Button

  import ZaqWeb.Components.DesignSystem.Table,
    only: [
      table: 1,
      table_actions: 1,
      table_cell: 1,
      table_head_row: 1,
      table_media: 1,
      table_row: 1,
      table_text: 1
    ]

  attr :teams, :list, required: true

  def teams_table(assigns) do
    ~H"""
    <.table id="teams-table" scrollable={true}>
      <:head>
        <.table_head_row>
          <.table_cell element={:th}>
            <.table_text label="Name" tone={:tertiary} />
          </.table_cell>
          <.table_cell element={:th} align={:right} width="w-24" />
        </.table_head_row>
      </:head>
      <:body>
        <.table_row :for={team <- @teams} id={"team-row-#{team.id}"}>
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
                  {String.first(team.name) |> String.upcase()}
                </span>
              </:icon>
              <div class="min-w-0">
                <.table_text label={team.name} />
                <.table_text
                  :if={team.description}
                  label={team.description}
                  tone={:tertiary}
                  truncate
                  class="line-clamp-1"
                />
              </div>
            </.table_media>
          </.table_cell>
          <.table_cell align={:right} width="w-24" nowrap>
            <.table_actions reveal={:hover}>
              <.button
                variant={:ghost}
                icon="hero-pencil-square"
                icon_only
                aria-label={"Edit #{team.name}"}
                title="Edit"
                phx-click="open_modal"
                phx-value-action="edit"
                phx-value-entity="team"
                phx-value-id={team.id}
              />
              <.button
                variant={:tertiary}
                danger
                icon="hero-trash"
                icon_only
                aria-label={"Delete #{team.name}"}
                title="Delete"
                phx-click="confirm_delete"
                phx-value-entity="team"
                phx-value-id={team.id}
              />
            </.table_actions>
          </.table_cell>
        </.table_row>
      </:body>
    </.table>
    """
  end
end

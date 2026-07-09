defmodule ZaqWeb.Dashboard.ServicesStatusTable do
  @moduledoc """
  BO main dashboard — cluster services health table (name, description, node, status).
  """

  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.Table,
    only: [
      table: 1,
      table_badge: 1,
      table_cell: 1,
      table_head_row: 1,
      table_row: 1,
      table_text: 1
    ]

  attr :services, :list, required: true

  def services_status_table(assigns) do
    ~H"""
    <div class="col-span-2">
      <.table id="dashboard-services-table">
        <:caption>Services</:caption>
        <:head>
          <.table_head_row>
            <.table_cell element={:th}>
              <.table_text label="Service" tone={:tertiary} />
            </.table_cell>
            <.table_cell element={:th}>
              <.table_text label="Description" tone={:tertiary} />
            </.table_cell>
            <.table_cell element={:th}>
              <.table_text label="Node" tone={:tertiary} />
            </.table_cell>
            <.table_cell element={:th} align={:right}>
              <.table_text label="Status" tone={:tertiary} />
            </.table_cell>
          </.table_head_row>
        </:head>
        <:body>
          <.table_row :for={svc <- @services}>
            <.table_cell>
              <.table_text label={svc.name} class="zaq-text-body-sm" />
            </.table_cell>
            <.table_cell>
              <.table_text label={svc.description} tone={:secondary} />
            </.table_cell>
            <.table_cell>
              <.table_text
                label={if svc.node, do: to_string(svc.node), else: "—"}
                tone={:tertiary}
              />
            </.table_cell>
            <.table_cell align={:right}>
              <.table_badge :if={svc.active} status="completed">Running</.table_badge>
              <.table_badge :if={!svc.active} status="cancelled">Disabled</.table_badge>
            </.table_cell>
          </.table_row>
        </:body>
      </.table>
    </div>
    """
  end
end

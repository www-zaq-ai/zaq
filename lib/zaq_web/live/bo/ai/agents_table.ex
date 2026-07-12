defmodule ZaqWeb.Live.BO.AI.AgentsTable do
  @moduledoc """
  BO agents master pane — selectable agent list table.
  """

  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.StatusDot, only: [status_dot: 1]

  import ZaqWeb.Components.DesignSystem.Table,
    only: [
      table: 1,
      table_badge: 1,
      table_cell: 1,
      table_empty: 1,
      table_head_row: 1,
      table_media: 1,
      table_row: 1,
      table_text: 1
    ]

  attr :agents, :list, required: true
  attr :selected_agent_id, :any, default: nil

  def agents_table(assigns) do
    ~H"""
    <.table id="agents-table" scrollable={true}>
      <:head>
        <.table_head_row>
          <.table_cell element={:th}>
            <.table_text label="Name" tone={:tertiary} />
          </.table_cell>
          <.table_cell element={:th}>
            <.table_text label="Model" tone={:tertiary} />
          </.table_cell>
          <.table_cell element={:th}>
            <.table_text label="Credential" tone={:tertiary} />
          </.table_cell>
          <.table_cell element={:th}>
            <.table_text label="Conversation" tone={:tertiary} />
          </.table_cell>
        </.table_head_row>
      </:head>
      <:body>
        <.table_empty :if={@agents == []} colspan={4}>
          No agents found.
        </.table_empty>
        <.table_row
          :for={agent <- @agents}
          id={"agent-row-#{agent.id}"}
          click="select_agent"
          click_values={%{id: agent.id}}
          variant={if(@selected_agent_id == agent.id, do: :selected, else: :default)}
        >
          <.table_cell>
            <.table_media>
              <:icon>
                <.status_dot status={if(agent.active, do: :active, else: :inactive)} />
              </:icon>
              <div class="min-w-0">
                <div class="zaq-layout-inline-compact">
                  <.table_text label={agent.name} tone={:mono} />
                  <.table_text label={"#" <> to_string(agent.id)} tone={:tertiary} />
                </div>
                <.table_text
                  label={agent.description || "No description"}
                  tone={:tertiary}
                  truncate
                  class="line-clamp-1"
                />
              </div>
            </.table_media>
          </.table_cell>
          <.table_cell>
            <.table_text label={agent.model} tone={:secondary} />
          </.table_cell>
          <.table_cell>
            <div class="flex flex-col gap-1">
              <.table_text
                label={(agent.credential && agent.credential.provider) || "—"}
                tone={:secondary}
              />
              <.table_badge :if={agent.credential && agent.credential.sovereign} status="processing">
                Sovereign
              </.table_badge>
              <.table_badge :if={!agent.credential || !agent.credential.sovereign} status="cancelled">
                Standard
              </.table_badge>
            </div>
          </.table_cell>
          <.table_cell>
            <.table_badge :if={agent.conversation_enabled} status="processing">
              Enabled
            </.table_badge>
            <.table_badge :if={!agent.conversation_enabled} status="cancelled">
              Disabled
            </.table_badge>
          </.table_cell>
        </.table_row>
      </:body>
    </.table>
    """
  end
end

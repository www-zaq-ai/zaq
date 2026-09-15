defmodule ZaqWeb.History.ConversationTable do
  @moduledoc """
  BO conversation history table — header, select-all, rows, and empty state.
  """

  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.Table,
    only: [
      table: 1,
      table_cell: 1,
      table_checkbox: 1,
      table_empty: 1,
      table_head_row: 1,
      table_text: 1
    ]

  import ZaqWeb.History.ConversationRow, only: [conversation_row: 1]
  alias ZaqWeb.History.ConversationRow

  attr :conversations, :list, required: true
  attr :selected, :any, required: true, doc: "MapSet of selected conversation ids."
  attr :live_action, :atom, required: true
  attr :is_admin, :boolean, required: true
  attr :filter_scope, :string, required: true
  attr :selectable, :boolean, default: true
  attr :actions, :boolean, default: true

  attr :destination, :any, default: &ConversationRow.bo_destination/1

  def conversation_table(assigns) do
    show_identity? = assigns.is_admin && assigns.filter_scope == "all"

    assigns =
      assigns
      |> assign(:show_identity?, show_identity?)
      |> assign(
        :empty_colspan,
        4 + if(show_identity?, do: 1, else: 0) +
          if(assigns.selectable, do: 1, else: 0) + if(assigns.actions, do: 1, else: 0)
      )

    ~H"""
    <.table
      id="history-conversations-table"
      min_width="768px"
      wrapper_class="overflow-x-auto min-w-0 max-w-full"
    >
      <:head>
        <.table_head_row>
          <.table_cell :if={@selectable} element={:th} width="w-10">
            <.table_checkbox
              phx-click="select_all"
              checked={
                @conversations != [] &&
                  MapSet.equal?(@selected, @conversations |> Enum.map(& &1.id) |> MapSet.new())
              }
            />
          </.table_cell>
          <.table_cell element={:th}>
            <.table_text label="Conversation" tone={:tertiary} />
          </.table_cell>
          <.table_cell :if={@show_identity?} element={:th}>
            <.table_text label="Identity" tone={:tertiary} />
          </.table_cell>
          <.table_cell element={:th}>
            <.table_text label="Channel" tone={:tertiary} />
          </.table_cell>
          <.table_cell element={:th}>
            <.table_text label="Started" tone={:tertiary} />
          </.table_cell>
          <.table_cell element={:th}>
            <.table_text label="Updated" tone={:tertiary} />
          </.table_cell>
          <.table_cell :if={@actions} element={:th} align={:right} />
        </.table_head_row>
      </:head>
      <:body>
        <.table_empty :if={@conversations == []} colspan={@empty_colspan}>
          No conversations found.
        </.table_empty>
        <.conversation_row
          :for={conv <- @conversations}
          conversation={conv}
          selected={@selected}
          live_action={@live_action}
          show_identity?={@show_identity?}
          selectable={@selectable}
          actions={@actions}
          destination={@destination}
        />
      </:body>
    </.table>
    """
  end
end

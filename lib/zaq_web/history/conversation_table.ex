defmodule ZaqWeb.History.ConversationTable do
  @moduledoc """
  BO conversation history table — header, select-all, rows, and empty state.
  """

  use Phoenix.Component

  import ZaqWeb.History.ConversationRow, only: [conversation_row: 1]

  attr :conversations, :list, required: true
  attr :selected, :any, required: true, doc: "MapSet of selected conversation ids."
  attr :live_action, :atom, required: true
  attr :is_admin, :boolean, required: true
  attr :filter_scope, :string, required: true

  def conversation_table(assigns) do
    assigns =
      assign(assigns, :show_identity?, assigns.is_admin && assigns.filter_scope == "all")

    ~H"""
    <div class="bg-white rounded-xl border border-black/10 overflow-hidden">
      <table class="w-full">
        <thead>
          <tr class="border-b border-black/10">
            <th class="w-10 px-4 py-3">
              <input
                type="checkbox"
                phx-click="select_all"
                checked={
                  @conversations != [] &&
                    MapSet.equal?(@selected, @conversations |> Enum.map(& &1.id) |> MapSet.new())
                }
                class="rounded border-black/20 text-[#03b6d4] cursor-pointer"
              />
            </th>
            <th class="text-left font-mono text-[0.7rem] text-black/40 uppercase tracking-wider px-4 py-3">
              Conversation
            </th>
            <th
              :if={@show_identity?}
              class="text-left font-mono text-[0.7rem] text-black/40 uppercase tracking-wider px-4 py-3"
            >
              Identity
            </th>
            <th class="text-left font-mono text-[0.7rem] text-black/40 uppercase tracking-wider px-4 py-3">
              Channel
            </th>
            <th class="text-left font-mono text-[0.7rem] text-black/40 uppercase tracking-wider px-4 py-3">
              Started
            </th>
            <th class="text-left font-mono text-[0.7rem] text-black/40 uppercase tracking-wider px-4 py-3">
              Updated
            </th>
            <th class="text-right font-mono text-[0.7rem] text-black/40 uppercase tracking-wider px-4 py-3">
            </th>
          </tr>
        </thead>
        <tbody>
          <.conversation_row
            :for={conv <- @conversations}
            conversation={conv}
            selected={@selected}
            live_action={@live_action}
            show_identity?={@show_identity?}
          />

          <tr :if={@conversations == []}>
            <td
              colspan={if @show_identity?, do: "7", else: "6"}
              class="px-6 py-12 text-center font-mono text-sm text-black/30"
            >
              No conversations found.
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end

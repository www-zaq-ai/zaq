defmodule ZaqWeb.History.ConversationRow do
  @moduledoc """
  One data row on the BO conversation history table.
  """

  use ZaqWeb, :html

  import ZaqWeb.Helpers.DateFormat, only: [format_datetime: 1]

  attr :conversation, :any,
    required: true,
    doc: "Preloaded conversation struct (engine list result)."

  attr :selected, :any, required: true, doc: "MapSet of selected conversation ids."
  attr :live_action, :atom, required: true
  attr :show_identity?, :boolean, required: true

  def conversation_row(assigns) do
    ~H"""
    <tr
      id={"conv-#{@conversation.id}"}
      class={[
        "border-b border-black/5 last:border-0 hover:bg-black/[0.02]",
        if(MapSet.member?(@selected, @conversation.id), do: "bg-[#03b6d4]/[0.03]", else: "")
      ]}
    >
      <td class="w-10 px-4 py-4">
        <input
          type="checkbox"
          phx-click="toggle_select"
          phx-value-id={@conversation.id}
          checked={MapSet.member?(@selected, @conversation.id)}
          class="rounded border-black/20 text-[#03b6d4] cursor-pointer"
        />
      </td>

      <td class="px-4 py-4 max-w-xs">
        <p class="font-mono text-sm text-black truncate">
          {@conversation.title || "(untitled)"}
        </p>
      </td>

      <td :if={@show_identity?} class="px-4 py-4">
        <.link
          :if={@conversation.person}
          navigate={~p"/bo/people?person_id=#{@conversation.person.id}"}
          class="font-mono text-[0.7rem] text-[#03b6d4] hover:underline"
        >
          {@conversation.person.full_name}
        </.link>
        <span
          :if={is_nil(@conversation.person) && @conversation.user}
          class="font-mono text-[0.7rem] text-black/50"
        >
          {@conversation.user.username}
        </span>
        <span
          :if={
            is_nil(@conversation.person) && is_nil(@conversation.user) &&
              @conversation.channel_user_id
          }
          class="font-mono text-[0.7rem] text-black/50"
        >
          {@conversation.channel_user_id}
        </span>
        <span
          :if={
            is_nil(@conversation.person) && is_nil(@conversation.user) &&
              is_nil(@conversation.channel_user_id)
          }
          class="font-mono text-[0.7rem] text-black/30"
        >
          —
        </span>
      </td>

      <td class="px-4 py-4">
        <span class="font-mono text-[0.7rem] px-2 py-1 rounded bg-black/5 text-black/50">
          {@conversation.channel_type}
        </span>
      </td>

      <td class="font-mono text-sm text-black/40 px-4 py-4">
        {format_datetime(@conversation.inserted_at)}
      </td>

      <td class="font-mono text-sm text-black/40 px-4 py-4">
        {format_datetime(@conversation.updated_at)}
      </td>

      <td class="px-4 py-4 text-right">
        <div class="flex items-center justify-end gap-3">
          <button
            :if={@live_action != :archived}
            type="button"
            phx-click="archive_conversation"
            phx-value-id={@conversation.id}
            class="font-mono text-[0.72rem] text-black/30 hover:text-black/60 transition-colors"
          >
            Archive
          </button>
          <button
            type="button"
            phx-click="delete_conversation"
            phx-value-id={@conversation.id}
            data-confirm="Delete this conversation? This cannot be undone."
            class="font-mono text-[0.72rem] text-red-400 hover:text-red-600 transition-colors"
          >
            Delete
          </button>
          <.link
            navigate={~p"/bo/conversations/#{@conversation.id}"}
            class="font-mono text-[0.75rem] text-[#03b6d4] hover:underline"
          >
            View →
          </.link>
        </div>
      </td>
    </tr>
    """
  end
end

defmodule Storybook.History.ConversationTable do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.History.ConversationTable

  @dt ~U[2025-01-10 08:00:00Z]
  @dt2 ~U[2025-02-01 12:00:00Z]

  def description,
    do:
      "BO History — full table with header, select-all, empty state, and rows (`ZaqWeb.History.ConversationTable`)."

  def render(assigns) do
    id1 = "11111111-1111-1111-1111-111111111111"
    id2 = "22222222-2222-2222-2222-222222222222"

    conversations = [
      %{
        id: id1,
        title: "E2E smoke conversation",
        person: %{id: 2, full_name: "Grace Hopper"},
        user: nil,
        channel_user_id: nil,
        channel_type: "bo",
        inserted_at: @dt,
        updated_at: @dt2
      },
      %{
        id: id2,
        title: "Alerts channel triage",
        person: nil,
        user: nil,
        channel_user_id: "mm-user-1",
        channel_type: "mattermost",
        inserted_at: @dt2,
        updated_at: @dt2
      }
    ]

    assigns =
      assigns
      |> assign(:empty_selected, MapSet.new())
      |> assign(:both_selected, MapSet.new([id1, id2]))
      |> assign(:conversations, conversations)

    ~H"""
    <div
      class="zaq-text-body flex flex-col gap-10"
      style="padding: var(--zaq-scale-32); max-width: 100%;"
    >
      <section class="flex flex-col gap-3 min-w-0">
        <h2 class="zaq-text-body font-semibold" style="color: var(--zaq-text-color-body-primary);">
          Empty (member / no identity column)
        </h2>
        <.conversation_table
          conversations={[]}
          selected={@empty_selected}
          live_action={:index}
          is_admin={false}
          filter_scope="own"
        />
      </section>

      <section class="flex flex-col gap-3 min-w-0">
        <h2 class="zaq-text-body font-semibold" style="color: var(--zaq-text-color-body-primary);">
          Populated — admin All Users (identity column + one selected row)
        </h2>
        <.conversation_table
          conversations={@conversations}
          selected={MapSet.new([id1])}
          live_action={:index}
          is_admin={true}
          filter_scope="all"
        />
      </section>

      <section class="flex flex-col gap-3 min-w-0">
        <h2 class="zaq-text-body font-semibold" style="color: var(--zaq-text-color-body-primary);">
          Select all checked
        </h2>
        <.conversation_table
          conversations={@conversations}
          selected={@both_selected}
          live_action={:index}
          is_admin={true}
          filter_scope="all"
        />
      </section>
    </div>
    """
  end
end

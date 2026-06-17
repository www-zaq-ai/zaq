defmodule Storybook.History.ConversationRow do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.History.ConversationRow.conversation_row/1

  def description,
    do:
      "BO History — one conversation row (checkbox, identity, actions) (`ZaqWeb.History.ConversationRow`)."

  @dt ~U[2025-01-10 08:00:00Z]
  @dt2 ~U[2025-02-01 12:00:00Z]

  def variations do
    id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    [
      %Variation{
        id: :with_person,
        description: "Identity shows linked person (All Users scope)",
        attributes: %{
          conversation: %{
            id: id,
            title: "Quarterly review",
            person: %{id: 1, full_name: "Ada Lovelace"},
            user: nil,
            channel_user_id: nil,
            channel_type: "bo",
            inserted_at: @dt,
            updated_at: @dt2
          },
          selected: MapSet.new(),
          live_action: :index,
          show_identity?: true
        }
      },
      %Variation{
        id: :username_only,
        description: "Identity shows BO username when no person",
        attributes: %{
          conversation: %{
            id: id,
            title: "(untitled)",
            person: nil,
            user: %{username: "ops_lead"},
            channel_user_id: nil,
            channel_type: "mattermost",
            inserted_at: @dt,
            updated_at: @dt
          },
          selected: MapSet.new([id]),
          live_action: :index,
          show_identity?: true
        }
      },
      %Variation{
        id: :archived_row,
        description: "Archived route — no per-row Archive button",
        attributes: %{
          conversation: %{
            id: id,
            title: "Old thread",
            person: nil,
            user: nil,
            channel_user_id: "ext-99",
            channel_type: "api",
            inserted_at: @dt,
            updated_at: @dt2
          },
          selected: MapSet.new(),
          live_action: :archived,
          show_identity?: false
        }
      }
    ]
  end
end

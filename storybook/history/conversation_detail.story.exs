defmodule Storybook.History.ConversationDetail do
  use PhoenixStorybook.Story, :component
  alias ZaqWeb.Components.DesignSystem.ConversationDetail
  def container, do: :iframe
  def function, do: &ConversationDetail.conversation_detail/1

  def variations do
    conversation = %{title: "Conversation", channel_type: "api", status: "active"}

    [
      %Variation{id: :bo, attributes: %{conversation: conversation, messages: []}},
      %Variation{
        id: :people,
        attributes: %{
          conversation: conversation,
          messages: [],
          back_url: "/people/history",
          can_share: false
        }
      }
    ]
  end
end

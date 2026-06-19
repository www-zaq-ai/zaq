defmodule Storybook.Modals.ChannelCapabilities do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.ChannelCapabilities.icon_with_modal/1

  def description,
    do: "Clickable info icon that opens a modal showing the capability snapshot for a channel."

  def variations do
    [
      %VariationGroup{
        id: :states,
        description: "Modal states",
        variations: [
          %Variation{
            id: :closed,
            description: "Modal closed",
            attributes: %{
              title: "Slack",
              modal_open?: false,
              snapshot: %{}
            }
          },
          %Variation{
            id: :open_with_snapshot,
            description: "Modal open with capability data",
            attributes: %{
              title: "Mattermost",
              modal_open?: true,
              snapshot: %{
                "can_send_messages" => true,
                "can_receive_messages" => true,
                "can_send_files" => false,
                "supports_threads" => true
              }
            }
          }
        ]
      }
    ]
  end
end

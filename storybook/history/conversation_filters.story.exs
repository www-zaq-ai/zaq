defmodule Storybook.History.ConversationFilters do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.History.ConversationFilters.conversation_filters/1

  def description,
    do:
      "BO History — conversation count, admin scope, team/person, channel filter (`ZaqWeb.History.ConversationFilters`)."

  @teams [%{id: 1, name: "Platform"}, %{id: 2, name: "Support"}]
  @people [%{id: 10, full_name: "Ada Lovelace"}, %{id: 11, full_name: "Grace Hopper"}]

  def variations do
    [
      %Variation{
        id: :member,
        description: "Non-admin: channel filter only",
        attributes: %{
          conversation_count: 3,
          is_admin: false,
          filter_scope: "own",
          filter_channel_type: "all",
          filter_team_id: "all",
          filter_person_id: "all",
          teams: [],
          people: []
        }
      },
      %Variation{
        id: :admin_own,
        description: "Super-admin, My History scope",
        attributes: %{
          conversation_count: 12,
          is_admin: true,
          filter_scope: "own",
          filter_channel_type: "bo",
          filter_team_id: "all",
          filter_person_id: "all",
          teams: @teams,
          people: @people
        }
      },
      %Variation{
        id: :admin_all,
        description: "Super-admin, All Users — team and person searchable selects visible",
        attributes: %{
          conversation_count: 120,
          is_admin: true,
          filter_scope: "all",
          filter_channel_type: "mattermost",
          filter_team_id: "1",
          filter_person_id: "10",
          teams: @teams,
          people: @people
        }
      }
    ]
  end
end

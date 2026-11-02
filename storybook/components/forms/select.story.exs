defmodule Storybook.Components.Forms.Select do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Select.select/1

  def description, do: "Design System dropdown using SearchableSelect with search disabled."

  def variations do
    [
      %VariationGroup{
        id: :select,
        description: "Select",
        variations: [
          %Variation{
            id: :default,
            description: "Default",
            attributes: %{
              name: "role",
              label: "Role",
              options: [{"Admin", "admin"}, {"User", "user"}, {"Viewer", "viewer"}],
              value: "user"
            }
          },
          %Variation{
            id: :default_short_value,
            description: "Default size — short “All” keeps min trigger width",
            attributes: %{
              name: "channel_type",
              label: "Channel",
              options: [
                {"All", "all"},
                {"BO", "bo"},
                {"Mattermost", "mattermost"},
                {"Slack", "slack"},
                {"Email", "email:imap"}
              ],
              value: "all"
            }
          },
          %Variation{
            id: :with_prompt,
            description: "With prompt",
            attributes: %{
              name: "role",
              label: "Role",
              prompt: "Choose a role…",
              options: [{"Admin", "admin"}, {"User", "user"}, {"Viewer", "viewer"}],
              value: nil
            }
          },
          %Variation{
            id: :with_error,
            description: "With validation error",
            attributes: %{
              name: "role",
              label: "Role",
              options: [{"Admin", "admin"}, {"User", "user"}],
              value: nil,
              errors: ["can't be blank"]
            }
          },
          %Variation{
            id: :with_hint,
            description: "With Design System field hint",
            attributes: %{
              name: "role",
              label: "Role",
              options: [{"Admin", "admin"}, {"User", "user"}],
              value: "user",
              hint: "Choose the least privileged role.",
              hint_id: "role-hint"
            }
          },
          %Variation{
            id: :compact,
            description: "Compact",
            attributes: %{
              name: "role",
              compact: true,
              prompt: "Role…",
              options: [{"Admin", "admin"}, {"Editor", "editor"}, {"Viewer", "viewer"}],
              value: nil
            }
          },
          %Variation{
            id: :compact_inline,
            description: "Compact with inline label",
            attributes: %{
              name: "status",
              label: "Status",
              label_position: "inline",
              compact: true,
              options: [{"Active", "active"}, {"Archived", "archived"}],
              value: "active"
            }
          },
          %Variation{
            id: :compact_inline_toolbar,
            description:
              "Compact toolbar filter — short “All” keeps min trigger width (History Channel)",
            attributes: %{
              name: "channel_type",
              label: "Channel",
              label_position: "inline",
              compact: true,
              options: [
                {"All", "all"},
                {"BO", "bo"},
                {"Mattermost", "mattermost"},
                {"Slack", "slack"},
                {"Email", "email:imap"}
              ],
              value: "all"
            }
          }
        ]
      }
    ]
  end
end

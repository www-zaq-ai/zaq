defmodule Storybook.Components.DesignSystem.TabNav do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.DesignSystem.TabNav.tab_nav/1

  def description do
    "Segmented tab bar for BO master panels (People / Teams). " <>
      "Inactive: tertiary text + hover secondary. Active: accent text + accent underline."
  end

  def container do
    {:div,
     class: "w-full max-w-md",
     style:
       "background: var(--zaq-surface-color-raised); border: var(--zaq-border-thickness-default) solid var(--zaq-border-color-default); border-radius: var(--zaq-scale-8); overflow: hidden;"}
  end

  @two_tabs [
    %{id: :people, label: "People"},
    %{id: :teams, label: "Teams"}
  ]

  @three_tabs [
    %{id: :overview, label: "Overview"},
    %{id: :members, label: "Members"},
    %{id: :settings, label: "Settings"}
  ]

  def variations do
    [
      %VariationGroup{
        id: :two_tabs,
        description: "Two tabs",
        variations: [
          %Variation{
            id: :people_active,
            description: "People active",
            attributes: %{active_tab: :people, tabs: @two_tabs}
          },
          %Variation{
            id: :teams_active,
            description: "Teams active",
            attributes: %{active_tab: :teams, tabs: @two_tabs}
          }
        ]
      },
      %VariationGroup{
        id: :three_tabs,
        description: "Three tabs",
        variations: [
          %Variation{
            id: :first_active,
            description: "First active",
            attributes: %{active_tab: :overview, tabs: @three_tabs}
          },
          %Variation{
            id: :middle_active,
            description: "Middle active",
            attributes: %{active_tab: :members, tabs: @three_tabs}
          },
          %Variation{
            id: :last_active,
            description: "Last active",
            attributes: %{active_tab: :settings, tabs: @three_tabs}
          }
        ]
      }
    ]
  end
end

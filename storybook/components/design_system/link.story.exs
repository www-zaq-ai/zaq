defmodule Storybook.Components.DesignSystem.Link do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.DesignSystem.Link.nav_link/1

  # Demo-only placeholder — callers pass their own `destination` at use site.
  @demo_destination "/bo/example-destination"

  def description do
    "BO underline navigation link. Pass **`destination`** (required) where the component is used — " <>
      "Storybook examples below only show a demo path (`#{@demo_destination}`). " <>
      "**Color:** `tone={:default}` (inherit from parent) or `tone={:accent}` — no other color modes. " <>
      "Optional `icon` with `icon_position` (`:left` default, `:right`). " <>
      "Sizes: `:default` (`.zaq-text-body`) or `:sm` (`.zaq-text-body-sm`)."
  end

  def container do
    {:div,
     style:
       "padding: var(--zaq-scale-24); background: var(--zaq-surface-color-base); color: var(--zaq-text-color-body-default); display: flex; flex-direction: column; gap: var(--zaq-scale-16); align-items: flex-start;"}
  end

  def variations do
    demo = @demo_destination
    base = %{destination: demo, external: true}

    [
      %VariationGroup{
        id: :default_tone,
        description: "tone={:default} — inherits parent color",
        variations: [
          %Variation{
            id: :text_only,
            description: "Default size, no icon",
            attributes: Map.merge(base, %{size: :default, tone: :default}),
            slots: ["Example link label"]
          },
          %Variation{
            id: :with_icon_right,
            description: "Default size, icon right",
            attributes:
              Map.merge(base, %{
                size: :default,
                tone: :default,
                icon: "hero-arrow-right",
                icon_position: :right
              }),
            slots: ["Example link label"]
          },
          %Variation{
            id: :small,
            description: "Small size, icon left",
            attributes:
              Map.merge(base, %{
                size: :sm,
                tone: :default,
                icon: "hero-arrow-right",
                icon_position: :left
              }),
            slots: ["Example link label"]
          }
        ]
      },
      %VariationGroup{
        id: :accent_tone,
        description: "tone={:accent} — semantic accent color",
        variations: [
          %Variation{
            id: :text_only,
            description: "Default size, no icon",
            attributes: Map.merge(base, %{size: :default, tone: :accent}),
            slots: ["Example link label"]
          },
          %Variation{
            id: :with_icon_right,
            description: "Default size, icon right",
            attributes:
              Map.merge(base, %{
                size: :default,
                tone: :accent,
                icon: "hero-arrow-right",
                icon_position: :right
              }),
            slots: ["Example link label"]
          },
          %Variation{
            id: :small,
            description: "Small size, icon left",
            attributes:
              Map.merge(base, %{
                size: :sm,
                tone: :accent,
                icon: "hero-arrow-right",
                icon_position: :left
              }),
            slots: ["Example link label"]
          }
        ]
      }
    ]
  end
end

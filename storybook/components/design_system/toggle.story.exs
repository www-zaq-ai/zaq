defmodule Storybook.Components.DesignSystem.Toggle do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.DesignSystem.Toggle.toggle/1

  def description,
    do:
      "Segmented control for two or more choices. Each choice supports icon only, text only, or text+icon."

  def variations do
    [
      %Variation{
        id: :icon_only,
        description: "Icon only (2 choices)",
        attributes: %{
          value: "list",
          event: "noop",
          value_param: "mode",
          choices: [
            %{value: "list", icon: "hero-bars-3", title: "List view"},
            %{value: "grid", icon: "hero-squares-2x2", title: "Grid view"}
          ]
        }
      },
      %Variation{
        id: :text_only,
        description: "Text only (3 choices)",
        attributes: %{
          value: "b",
          event: "noop",
          choices: [
            %{value: "a", label: "Alpha"},
            %{value: "b", label: "Beta"},
            %{value: "c", label: "Gamma"}
          ]
        }
      },
      %Variation{
        id: :text_and_icon,
        description: "Text + icon (3 choices)",
        attributes: %{
          value: "grid",
          event: "noop",
          value_param: "mode",
          suffix: "12 item(s)",
          choices: [
            %{value: "list", label: "List", icon: "hero-bars-3"},
            %{value: "grid", label: "Grid", icon: "hero-squares-2x2"},
            %{value: "table", label: "Table", icon: "hero-table-cells"}
          ]
        }
      },
      %Variation{
        id: :text_and_provider_icon,
        description: "Text + channel provider icon (ingestion sources)",
        attributes: %{
          value: "volume:documents",
          event: "noop",
          value_param: "source",
          choices: [
            %{value: "volume:documents", label: "documents", provider: "zaq_local"},
            %{value: "volume:archives", label: "archives", provider: "zaq_local"},
            %{value: "provider:google_drive", label: "Google Drive", provider: "google_drive"}
          ]
        }
      },
      %Variation{
        id: :pill_icons,
        description: "Pill variant — icon only (3 choices)",
        attributes: %{
          value: "light",
          event: "noop",
          value_param: "theme",
          variant: :pill,
          choices: [
            %{value: "system", icon: "hero-computer-desktop-micro", title: "System theme"},
            %{value: "light", icon: "hero-sun-micro", title: "Light theme"},
            %{value: "dark", icon: "hero-moon-micro", title: "Dark theme"}
          ]
        }
      }
    ]
  end
end

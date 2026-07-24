defmodule Storybook.Components.Forms.Switch do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.DesignSystem.Switch.switch/1

  def description,
    do: "Boolean pill switch — check icon in knob when on; 64×32px track."

  def variations do
    [
      %VariationGroup{
        id: :inline,
        description: "Inline boolean (AI credential sovereign)",
        variations: [
          %Variation{
            id: :inline_off,
            description: "Unchecked",
            attributes: %{
              id: "sovereign",
              name: "ai_credential[sovereign]",
              label: "Sovereign credential",
              value: false
            }
          },
          %Variation{
            id: :inline_on,
            description: "Checked",
            attributes: %{
              id: "sovereign-on",
              name: "ai_credential[sovereign]",
              label: "Sovereign credential",
              value: true
            }
          },
          %Variation{
            id: :inline_disabled,
            description: "Disabled",
            attributes: %{
              id: "sovereign-disabled",
              name: "ai_credential[sovereign]",
              label: "Sovereign credential",
              value: true,
              disabled: true
            }
          }
        ]
      },
      %VariationGroup{
        id: :setting_row,
        description: "Settings row (telemetry capture)",
        variations: [
          %Variation{
            id: :setting_row_off,
            description: "Unchecked",
            attributes: %{
              id: "capture-infra",
              name: "telemetry_config[capture_infra_metrics]",
              layout: :setting_row,
              label: "Capture infra metrics",
              description: "Collect Phoenix request, Repo query, and Oban runtime metrics.",
              value: false
            }
          },
          %Variation{
            id: :setting_row_on,
            description: "Checked",
            attributes: %{
              id: "capture-infra-on",
              name: "telemetry_config[capture_infra_metrics]",
              layout: :setting_row,
              label: "Capture infra metrics",
              description: "Collect Phoenix request, Repo query, and Oban runtime metrics.",
              value: true
            }
          }
        ]
      },
      %VariationGroup{
        id: :enum,
        description: "Enum status (MCP endpoint — UI-only checkbox)",
        variations: [
          %Variation{
            id: :enum_enabled,
            description: "Enabled",
            attributes: %{
              id: "mcp-status-enabled",
              name: "mcp_endpoint[status]",
              mode: :enum,
              on_value: "enabled",
              off_value: "disabled",
              on_label: "Enabled",
              off_label: "Disabled",
              value: "enabled"
            }
          },
          %Variation{
            id: :enum_disabled,
            description: "Disabled",
            attributes: %{
              id: "mcp-status-disabled",
              name: "mcp_endpoint[status]",
              mode: :enum,
              on_value: "enabled",
              off_value: "disabled",
              on_label: "Enabled",
              off_label: "Disabled",
              value: "disabled"
            }
          }
        ]
      },
      %VariationGroup{
        id: :errors,
        description: "With validation errors",
        variations: [
          %Variation{
            id: :with_error,
            description: "Field error",
            attributes: %{
              id: "sovereign-error",
              name: "ai_credential[sovereign]",
              label: "Sovereign credential",
              value: false,
              errors: ["must be accepted for this region"]
            }
          }
        ]
      }
    ]
  end
end

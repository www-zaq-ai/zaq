defmodule Storybook.Ingestion.LabelEditor do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component
  alias ZaqWeb.Components.DesignSystem.{LabelChips, LabelEditor}

  def description, do: "Typed label values and staged editing with pending automatic assignments."

  def render(assigns) do
    assigns =
      assign(assigns,
        labels: [
          %{
            id: 1,
            name: "Approved",
            description: "Boolean decision",
            value_type: "boolean",
            value_config: %{},
            value: false,
            state: :assigned
          },
          %{
            id: 2,
            name: "Score",
            description: "Scale from 0 to 10 in increments of 0.5",
            value_type: "scale",
            value_config: %{"min" => 0, "max" => 10, "increment" => 0.5},
            value: 0,
            state: :assigned
          },
          %{
            id: 3,
            name: "Office",
            description: "Choose a definition-owned option",
            value_type: "options",
            value_config: %{
              "options" => [
                %{"id" => "office-1", "label" => "Paris"},
                %{"id" => "office-2", "label" => "London"}
              ]
            },
            value: "office-1",
            state: :assigned
          },
          %{
            id: 4,
            name: "Review",
            description: "Automatic assignment awaits evaluation",
            value_type: "boolean",
            value_config: %{},
            value: nil,
            state: :pending
          },
          %{
            id: 5,
            name: "Excluded label",
            description: "Explicit exclusion",
            value_type: "boolean",
            value_config: %{},
            value: nil,
            state: :excluded
          }
        ]
      )

    ~H"""
    <div class="zaq-layout-stack">
      <LabelChips.label_chips labels={Enum.take(@labels, 2)} resource_id={1} />
      <LabelChips.label_chips labels={Enum.drop(@labels, 2)} resource_id={2} />
      <LabelEditor.label_editor
        labels={@labels}
        selected={MapSet.new([1, 2, 3, 4])}
        editable={true}
        query="Excluded"
      />
    </div>
    """
  end
end

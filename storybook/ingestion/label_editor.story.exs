defmodule Storybook.Ingestion.LabelEditor do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component
  alias ZaqWeb.Components.DesignSystem.{LabelChips, LabelEditor}

  def description, do: "Manual category chips and Share-style staged label editing."

  def render(assigns) do
    assigns = assign(assigns, labels: [
      %{id: 1, name: "Location", description: "Location associated with this resource", value: "Paris"},
      %{id: 2, name: "Architecture", description: "System design and scalability"},
      %{id: 3, name: "FinTech", description: "Financial technology documents"}
    ])

    ~H"""
    <div class="zaq-layout-stack">
      <LabelChips.label_chips labels={Enum.take(@labels, 1)} resource_id={1} />
      <LabelEditor.label_editor labels={@labels} selected={MapSet.new([1, 2])} editable={true}
        values={%{1 => "Paris"}} suggestions={%{1 => ["London", "Paris"]}} />
    </div>
    """
  end
end

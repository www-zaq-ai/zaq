defmodule Storybook.Components.DesignSystem.PersonProfile do
  use PhoenixStorybook.Story, :component
  # Page-scoped IDs and hooks require a separate document per variation.
  def container, do: :iframe
  def function, do: &ZaqWeb.Components.DesignSystem.PersonProfile.person_profile/1
  def description, do: "Production profile content with parent-owned name and channel-order drafts. Name validation comes from production; teams are read-only."
  def variations do
    channels = [
      %{id: "email", platform: "Email", provider: "email", identifier: "alex@example.test"},
      %{id: "other", platform: "Custom", provider: "custom", identifier: String.duplicate("long-identifier-", 8)}
    ]
    profile = %{person: %{full_name: "Alex Morgan", email: "alex@example.test", phone: nil, role: "Staff", status: "active"}, teams: ["Product", "Research"], channels: channels, editable: true}
    base = %{profile: profile, mode: :read, name_form: Phoenix.Component.to_form(%{"full_name" => "Alex Morgan"}, as: :profile), draft_channels: channels}
    [
      %Variation{id: :read, attributes: base},
      %Variation{id: :name, attributes: %{base | mode: :name}},
      %Variation{id: :invalid_name, attributes: Map.merge(base, %{mode: :name, name_errors: ["is invalid"]})},
      %Variation{id: :order, attributes: %{base | mode: :order, draft_channels: Enum.reverse(channels)}},
      %Variation{id: :empty_read_only, attributes: %{base | profile: %{profile | editable: false, teams: [], channels: []}, draft_channels: []}}
    ]
  end
end

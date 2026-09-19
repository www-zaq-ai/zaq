defmodule Storybook.Components.DesignSystem.PersonHeader do
  use PhoenixStorybook.Story, :component
  def container, do: :iframe
  def function, do: &ZaqWeb.Components.DesignSystem.PersonHeader.person_header/1

  def description,
    do:
      "Shared People header: branding, mobile-aware heading, theme controls inside Settings, capability-gated destinations, and account actions; no sidebar."

  def variations do
    variations =
      for {id, name} <- [
            named: "Alex Morgan",
            blank: nil,
            long: "Alexandra Morgan — International Customer Experience"
          ] do
        %Variation{
          id: id,
          attributes: %{
            title: "Profile",
            description: "Your details, your teams, and how ZAQ can reach you.",
            display_name: name
          }
        }
      end

    variations ++
      [
        %Variation{
          id: :history,
          attributes: %{title: "Conversations", display_name: "Alex Morgan", history_access: true}
        }
      ]
  end
end

defmodule Storybook.Components.DesignSystem.PersonHeader do
  use PhoenixStorybook.Story, :component
  def container, do: :iframe
  def function, do: &ZaqWeb.Components.DesignSystem.PersonHeader.person_header/1

  def description,
    do:
      "Shared PageHeader and AccountMenu on People: branding, theme, capability-gated Conversations settings and independent People destinations; no sidebar."

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
            description: "Your information and how we contact you.",
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

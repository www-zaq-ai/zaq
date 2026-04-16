defmodule Storybook.CoreComponents.Flash do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.CoreComponents.flash/1
  def description, do: "Toast-style flash notification. Two kinds: :info and :error."

  def variations do
    [
      %Variation{
        id: :info,
        description: "Info",
        attributes: %{kind: :info},
        slots: ["Document ingestion completed successfully."]
      },
      %Variation{
        id: :error,
        description: "Error",
        attributes: %{kind: :error},
        slots: ["Something went wrong. Please try again."]
      },
      %Variation{
        id: :info_with_title,
        description: "Info with title",
        attributes: %{kind: :info, title: "Import complete"},
        slots: ["42 documents were added to the knowledge base."]
      }
    ]
  end
end

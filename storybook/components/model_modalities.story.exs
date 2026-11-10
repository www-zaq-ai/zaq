defmodule Storybook.Components.ModelModalities do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.DesignSystem.ModelModalities.model_modalities/1

  def description,
    do: "Catalog model input → output icons. Hover, focus or tap an icon for its direction and label."

  def variations do
    [
      %Variation{
        id: :multimodal,
        attributes: %{
          id: "multimodal",
          modalities: %{input: [:text, :image, :audio, :video, :pdf], output: [:text, :audio]}
        }
      },
      %Variation{
        id: :text_only,
        attributes: %{id: "text-only", modalities: %{input: [:text], output: [:text]}}
      },
      %Variation{
        id: :partial,
        attributes: %{id: "partial", modalities: %{input: [:text, :image]}}
      },
      %Variation{id: :unknown, attributes: %{id: "unknown"}},
      %Variation{id: :unselected, attributes: %{id: "unselected", selected: false}}
    ]
  end
end

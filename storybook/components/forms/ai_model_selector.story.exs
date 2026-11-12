defmodule Storybook.Components.Forms.AIModelSelector do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.DesignSystem.AIModelSelector.ai_model_selector/1

  def description,
    do: "Provider and model selection with manual custom IDs and inline catalog modalities."

  def variations do
    for {id, overrides} <- [
          inline: %{},
          stacked: %{layout: :stacked},
          custom: %{options: [], model_catalogs: %{"12" => []}},
          locked: %{layout: :stacked, model_disabled: true}
        ] do
      %Variation{
        id: id,
        attributes:
          Map.merge(
            %{
              id_prefix: "model-#{id}",
              form:
                Phoenix.Component.to_form(%{"credential_id" => "12", "model" => "example-model"},
                  as: :model_config
                ),
              credential_options: [{"Example provider", "12"}],
              options: [{"Example model", "example-model"}],
              model_catalogs: %{
                "12" => [
                  %{id: "example-model", modalities: %{input: [:text, :image], output: [:text]}}
                ]
              }
            },
            overrides
          )
      }
    end
  end
end

defmodule Storybook.Patterns.RAGConfiguration do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  alias Zaq.System.{EmbeddingConfig, ImageToTextConfig, LLMConfig, OperationModelConfig, RAGModelConfig}
  alias ZaqWeb.Live.BO.System.SystemConfig.RAGTab

  def description,
    do:
      "RAG settings: locked embeddings, advanced retrieval, image extraction and saved-only specialized models."

  def render(assigns) do
    assigns =
      assigns
      |> assign(
        :embedding_form,
        to_form(EmbeddingConfig.changeset(%EmbeddingConfig{}, %{}), as: :embedding_config)
      )
      |> assign(
        :image_form,
        to_form(ImageToTextConfig.changeset(%ImageToTextConfig{}, %{}), as: :image_to_text_config)
      )
      |> assign(
        :retrieval_form,
        to_form(LLMConfig.retrieval_changeset(%LLMConfig{}, %{}), as: :retrieval_config)
      )
      |> assign(
        :model_forms,
        Map.new(
          [:reranking, :decision],
          &{&1, to_form(RAGModelConfig.changeset(%RAGModelConfig{}, %{}), as: :rag_model_config)}
        )
      )

    ~H"""
    <RAGTab.panel
      embedding_form={@embedding_form}
      image_to_text_form={@image_form}
      retrieval_form={@retrieval_form}
      translation_form={to_form(OperationModelConfig.changeset(%OperationModelConfig{}, %{}), as: :operation_model_config)}
      translation_model_options={[]}
      model_forms={@model_forms}
      credential_options={[{"Example provider credential", "1"}]}
      embedding_model_options={[]}
      image_to_text_model_options={[]}
      model_options={%{reranking: [], decision: []}}
      locked={true}
      unlock_modal={false}
      save_confirm_modal={false}
      model_changed={false}
    />
    """
  end
end

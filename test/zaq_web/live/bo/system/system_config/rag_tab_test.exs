defmodule ZaqWeb.Live.BO.System.SystemConfig.RAGTabTest do
  use ZaqWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias Zaq.System.{
    EmbeddingConfig,
    ImageToTextConfig,
    LLMConfig,
    OperationModelConfig,
    RAGModelConfig
  }

  alias ZaqWeb.Live.BO.System.SystemConfig.RAGTab

  test "groups advanced retrieval under Retrieval and preserves embedding lock controls" do
    html =
      render_component(&RAGTab.panel/1,
        embedding_form:
          Phoenix.Component.to_form(EmbeddingConfig.changeset(%EmbeddingConfig{}, %{}),
            as: :embedding_config
          ),
        image_to_text_form:
          Phoenix.Component.to_form(ImageToTextConfig.changeset(%ImageToTextConfig{}, %{}),
            as: :image_to_text_config
          ),
        retrieval_form:
          Phoenix.Component.to_form(LLMConfig.retrieval_changeset(%LLMConfig{}, %{}),
            as: :retrieval_config
          ),
        model_forms:
          Map.new(
            [:reranking, :decision],
            &{&1,
             Phoenix.Component.to_form(RAGModelConfig.changeset(%RAGModelConfig{}, %{}),
               as: :rag_model_config
             )}
          ),
        credential_options: [],
        translation_form:
          Phoenix.Component.to_form(OperationModelConfig.changeset(%OperationModelConfig{}, %{}),
            as: :operation_model_config
          ),
        translation_model_options: [],
        embedding_model_options: [],
        image_to_text_model_options: [],
        model_options: %{reranking: [], decision: []},
        locked: true,
        unlock_modal: false,
        save_confirm_modal: false,
        model_changed: false
      )

    assert html =~ "Embeddings &amp; chunking"
    assert html =~ "unlock_embedding"
    assert html =~ "rag-retrieval-advanced"
    assert html =~ "No compatible models"
    assert html =~ "Saved for future use"
    refute html =~ "bg-white"
    refute html =~ "text-black"
    doc = LazyHTML.from_fragment(html)

    refute Enum.empty?(
             LazyHTML.query(
               doc,
               "#retrieval-section #rag-retrieval-advanced #retrieval-config-form"
             )
           )

    assert Enum.empty?(LazyHTML.query(doc, "form form"))
    refute Enum.empty?(LazyHTML.query(doc, "#embedding_config_dimension[disabled]"))
  end
end

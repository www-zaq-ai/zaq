defmodule ZaqWeb.Live.BO.System.SystemConfig.LLMTabTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset, only: [add_error: 3]
  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest

  alias Zaq.System.{
    EmbeddingConfig,
    ImageToTextConfig,
    LLMConfig,
    OperationModelConfig,
    RAGModelConfig
  }

  alias ZaqWeb.Live.BO.System.SystemConfig.LLMTab
  alias ZaqWeb.Live.BO.System.SystemConfig.RAGTab

  test "model validation error renders below the model text input" do
    error = "model value rejected"
    html = render_panel(%{model: error})

    assert [form_tag] = Regex.run(~r/<form\b[^>]*>/, html)
    assert form_tag =~ ~s(phx-submit="save_llm")
    assert form_tag =~ ~s(phx-change="validate_llm")
    assert form_tag =~ ~s(id="llm-config-form")
    assert field_error(html, "model") == error
    refute field_error(html, "credential_id") =~ error
  end

  test "maximum cosine distance error is distinct from its help text" do
    error = "cosine distance exceeds maximum"
    html = render_panel(%{max_cosine_distance: error})

    assert field_error(html, "max_cosine_distance") == error
    refute field_error(html, "fusion_vector_weight") =~ error

    valid_html = render_panel(%{})
    assert field_error(valid_html, "max_cosine_distance") == ""

    assert field_help(valid_html, "max_cosine_distance") =~
             "Lower is closer; cosine similarity is 1 − distance."
  end

  test "fusion vector weight error stays in its field within the advanced section" do
    error = "vector weight exceeds maximum"
    html = render_panel(%{fusion_vector_weight: error})

    assert html =~ ~s(<details id="rag-retrieval-advanced")
    assert field_error(html, "fusion_vector_weight") == error
    refute field_error(html, "fusion_bm25_weight") =~ error
  end

  test "fusion vector and BM25 errors remain attached to their respective fields" do
    vector_error = "vector weight rejected"
    bm25_error = "BM25 weight rejected"
    html = render_panel(%{fusion_vector_weight: vector_error, fusion_bm25_weight: bm25_error})

    assert field_error(html, "fusion_vector_weight") == vector_error
    assert field_error(html, "fusion_bm25_weight") == bm25_error
  end

  defp render_panel(errors) do
    changeset =
      Enum.reduce(
        errors,
        %LLMConfig{} |> LLMConfig.changeset(%{credential_id: 1, model: "test-model"}),
        fn {field, message}, changeset ->
          add_error(changeset, field, message)
        end
      )
      |> Map.put(:action, :validate)
      |> then(fn cs ->
        %{
          cs
          | params:
              Map.merge(
                cs.params || %{},
                Map.new(errors, fn {field, _} -> {to_string(field), "0.5"} end)
              )
        }
      end)

    if Map.has_key?(errors, :model) do
      render_component(&LLMTab.panel/1,
        form: to_form(changeset, as: :llm_config),
        credential_options: [],
        model_options: [],
        capabilities: %{}
      )
    else
      render_component(&RAGTab.panel/1,
        embedding_form:
          to_form(EmbeddingConfig.changeset(%EmbeddingConfig{}, %{}), as: :embedding_config),
        image_to_text_form:
          to_form(ImageToTextConfig.changeset(%ImageToTextConfig{}, %{}),
            as: :image_to_text_config
          ),
        retrieval_form: to_form(changeset, as: :retrieval_config),
        translation_form:
          to_form(
            OperationModelConfig.changeset(%OperationModelConfig{}, %{}),
            as: :operation_model_config
          ),
        translation_model_options: [],
        model_forms:
          Map.new(
            [:reranking, :decision],
            &{&1,
             to_form(RAGModelConfig.changeset(%RAGModelConfig{}, %{}), as: :rag_model_config)}
          ),
        model_options: %{reranking: [], decision: []},
        credential_options: [],
        embedding_model_options: [],
        image_to_text_model_options: [],
        locked: true,
        unlock_modal: false,
        save_confirm_modal: false,
        model_changed: false
      )
    end
  end

  defp field_error(html, field) do
    field_message(html, field, ".zaq-field-error")
  end

  defp field_help(html, field) do
    field_message(html, field, ".zaq-field-hint")
  end

  defp field_message(html, field, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".zaq-field-row-block:has(input[name$='[#{field}]']) #{selector}")
    |> LazyHTML.text()
    |> String.trim()
  end
end

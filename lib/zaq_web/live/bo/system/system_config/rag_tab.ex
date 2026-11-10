defmodule ZaqWeb.Live.BO.System.SystemConfig.RAGTab do
  @moduledoc "Theme-aware RAG configuration layout for retrieval, embeddings and reranking."
  use ZaqWeb, :html
  alias ZaqWeb.Components.DesignSystem.{Button, CardShell, Input}
  alias ZaqWeb.Live.BO.System.SystemConfig.{EmbeddingTab, ImageToTextTab, OperationModelFields}

  attr :embedding_form, :any, required: true
  attr :image_to_text_form, :any, required: true
  attr :retrieval_form, :any, required: true
  attr :translation_form, :any, required: true
  attr :translation_model_options, :list, required: true
  attr :translation_manual_model, :boolean, default: false
  attr :model_catalogs, :map, default: %{}
  attr :model_forms, :map, required: true
  attr :credential_options, :list, required: true
  attr :embedding_model_options, :list, required: true
  attr :image_to_text_model_options, :list, required: true
  attr :model_options, :map, required: true
  attr :locked, :boolean, required: true
  attr :unlock_modal, :boolean, required: true
  attr :save_confirm_modal, :boolean, required: true
  attr :model_changed, :boolean, required: true

  def panel(assigns) do
    ~H"""
    <div id="rag-config" class="space-y-5">
      <EmbeddingTab.panel
        form={@embedding_form}
        credential_options={@credential_options}
        model_options={@embedding_model_options}
        model_catalogs={@model_catalogs}
        locked={@locked}
        unlock_modal={@unlock_modal}
        save_confirm_modal={@save_confirm_modal}
        model_changed={@model_changed}
      />
      <div id="rag-image-model-row" class="grid grid-cols-1 xl:grid-cols-2 gap-5">
        <ImageToTextTab.panel
          form={@image_to_text_form}
          credential_options={@credential_options}
          model_options={@image_to_text_model_options}
          model_catalogs={@model_catalogs}
          stacked={true}
        />
        <.model_section
          kind={:reranking}
          title="Re-ranking"
          form={@model_forms.reranking}
          options={@model_options.reranking}
          credential_options={@credential_options}
          model_catalogs={@model_catalogs}
        />
      </div>
      <CardShell.card_shell id="retrieval-section">
        <div class="space-y-5">
          <header>
            <h2 class="zaq-text-h3" style="color: var(--zaq-text-color-body-default)">Retrieval</h2>
            <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
              Knowledge-query translation — prepares searches in the detected document languages.
            </p>
          </header>
          <OperationModelFields.selection_form
            kind={:translation}
            title="Knowledge-query Translation"
            form={@translation_form}
            options={@translation_model_options}
            manual_model={@translation_manual_model}
            model_catalogs={@model_catalogs}
            credential_options={@credential_options}
          />
          <details id="rag-retrieval-advanced" phx-hook="DetailsKeepOpen">
            <summary
              class="zaq-text-body-sm cursor-pointer"
              style="color: var(--zaq-text-color-body-accent)"
            >
              Advanced settings — Retrieval tuning
            </summary>
            <.form
              id="retrieval-config-form"
              for={@retrieval_form}
              phx-change="validate_retrieval"
              phx-submit="save_retrieval"
              class="space-y-4 mt-4"
            >
              <Input.input
                field={@retrieval_form[:max_cosine_distance]}
                type="number"
                label="Maximum cosine distance"
                min="0"
                max="2"
                step="0.01"
                hint="Lower is closer; cosine similarity is 1 − distance."
              />
              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <Input.input
                  field={@retrieval_form[:fusion_bm25_weight]}
                  type="number"
                  label="BM25 Weight"
                  min="0"
                  max="1"
                  step="0.01"
                />
                <Input.input
                  field={@retrieval_form[:fusion_vector_weight]}
                  type="number"
                  label="Vector Weight"
                  min="0"
                  max="1"
                  step="0.01"
                />
              </div>
              <Button.button type="submit">Save Retrieval Settings</Button.button>
            </.form>
          </details>
        </div>
      </CardShell.card_shell>
    </div>
    """
  end

  attr :kind, :atom, required: true
  attr :title, :string, required: true
  attr :form, :any, required: true
  attr :options, :list, required: true
  attr :credential_options, :list, required: true
  attr :model_catalogs, :map, default: %{}

  defp model_section(assigns) do
    ~H"""
    <CardShell.card_shell id={"rag-#{@kind}-section"}>
      <div class="space-y-4">
        <header>
          <h2 class="zaq-text-h3" style="color: var(--zaq-text-color-body-default)">{@title}</h2>
          <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-secondary)">
            Saved for future use. Not active in the RAG pipeline.
          </p>
        </header>
        <.form
          id={"rag-#{@kind}-form"}
          for={@form}
          phx-change="validate_rag_model"
          phx-submit="save_rag_model"
          class="space-y-4"
        >
          <input type="hidden" name="kind" value={@kind} />
          <OperationModelFields.fields
            id_prefix={"rag-#{@kind}"}
            form={@form}
            options={@options}
            credential_options={@credential_options}
            stacked={true}
            model_catalogs={@model_catalogs}
            manual_model={
              Map.get(@model_catalogs, to_string(@form[:credential_id].value || "")) == []
            }
          />
          <p
            :if={
              @options == [] and
                Map.get(@model_catalogs, to_string(@form[:credential_id].value || "")) != []
            }
            class="zaq-text-caption"
            style="color: var(--zaq-text-color-body-secondary)"
          >
            No compatible models. Select a provider credential with {@title |> String.downcase()} models.
          </p>
          <Button.button type="submit">Save {@title} Settings</Button.button>
        </.form>
      </div>
    </CardShell.card_shell>
    """
  end
end

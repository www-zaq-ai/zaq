defmodule ZaqWeb.Live.BO.System.SystemConfig.RAGTab do
  @moduledoc "Theme-aware RAG configuration layout, including saved-only specialized selections."
  use ZaqWeb, :html
  alias ZaqWeb.Components.DesignSystem.{Button, CardShell, Input}
  alias ZaqWeb.Live.BO.System.SystemConfig.{EmbeddingTab, ImageToTextTab, OperationModelFields}
  import ZaqWeb.Components.SearchableSelect

  attr :embedding_form, :any, required: true
  attr :image_to_text_form, :any, required: true
  attr :retrieval_form, :any, required: true
  attr :translation_form, :any, required: true
  attr :translation_model_options, :list, required: true
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
        locked={@locked}
        unlock_modal={@unlock_modal}
        save_confirm_modal={@save_confirm_modal}
        model_changed={@model_changed}
      />
      <ImageToTextTab.panel
        form={@image_to_text_form}
        credential_options={@credential_options}
        model_options={@image_to_text_model_options}
      />
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
      <div class="grid grid-cols-1 xl:grid-cols-2 gap-5">
        <.model_section
          :for={{kind, title} <- [reranking: "Re-ranking", decision: "Decision"]}
          kind={kind}
          title={title}
          form={@model_forms[kind]}
          options={@model_options[kind]}
          credential_options={@credential_options}
        />
      </div>
    </div>
    """
  end

  attr :kind, :atom, required: true
  attr :title, :string, required: true
  attr :form, :any, required: true
  attr :options, :list, required: true
  attr :credential_options, :list, required: true

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
          <.searchable_select
            id={"rag-#{@kind}-credential-select"}
            name="rag_model_config[credential_id]"
            label="Provider / AI credential"
            label_position="block"
            value={to_string(@form[:credential_id].value || "")}
            options={[{"Not configured", ""} | @credential_options]}
            empty_label="Select a credential..."
          />
          <p :for={error <- @form[:credential_id].errors} class="zaq-field-error zaq-text-caption">
            {translate_error(error)}
          </p>
          <.searchable_select
            id={"rag-#{@kind}-model-select"}
            name="rag_model_config[model]"
            label="Model"
            label_position="block"
            value={@form[:model].value}
            options={@options}
            empty_label="Select a compatible model..."
          />
          <p :for={error <- @form[:model].errors} class="zaq-field-error zaq-text-caption">
            {translate_error(error)}
          </p>
          <p
            :if={@options == []}
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

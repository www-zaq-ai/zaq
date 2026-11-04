defmodule ZaqWeb.Live.BO.System.SystemConfig.EmbeddingTab do
  @moduledoc "Embedding settings and the existing unlock/destructive-save confirmation flow."
  use ZaqWeb, :html
  alias ZaqWeb.Components.BOModal
  alias ZaqWeb.Components.DesignSystem.{Button, CardShell, Input}
  import ZaqWeb.Components.SearchableSelect

  attr :form, :any, required: true
  attr :credential_options, :list, required: true
  attr :model_options, :list, required: true
  attr :locked, :boolean, default: false
  attr :unlock_modal, :boolean, default: false
  attr :model_changed, :boolean, default: false
  attr :save_confirm_modal, :boolean, default: false
  slot :advanced

  def panel(assigns) do
    ~H"""
    <BOModal.modal_shell
      :if={@unlock_modal}
      id="embedding-unlock-modal"
      title="Unlock Model Selection"
      cancel_event="cancel_unlock_embedding"
    >
      <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
        You are about to unlock model selection. If you pick a different model, saving will permanently delete all existing embeddings and require full re-ingestion.
      </p>
      <div class="flex justify-end gap-3 mt-5">
        <Button.button variant={:secondary} phx-click="cancel_unlock_embedding">Cancel</Button.button>
        <Button.button phx-click="confirm_unlock_embedding">Unlock</Button.button>
      </div>
    </BOModal.modal_shell>
    <BOModal.confirm_dialog
      :if={@save_confirm_modal}
      id="embedding-save-confirm-modal"
      title="Delete All Embeddings?"
      cancel_event="cancel_save_embedding"
      confirm_event="confirm_save_embedding"
      confirm_label="Proceed"
      message="All existing embeddings will be permanently deleted and full re-ingestion will be required. This cannot be undone."
    />
    <CardShell.card_shell id="embedding-section">
      <div class="space-y-5">
        <header class="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h2 class="zaq-text-h3" style="color: var(--zaq-text-color-body-default)">
              Embeddings &amp; chunking
            </h2>
            <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
              Configure vector embeddings and document chunk sizes.
            </p>
          </div>
          <div :if={@locked} class="flex items-center gap-2">
            <span class="zaq-text-caption" style="color: var(--zaq-text-color-body-success)">Locked</span>
            <Button.button variant={:secondary} phx-click="unlock_embedding" icon="hero-lock-closed">Unlock</Button.button>
          </div>
        </header>
        <.form
          id="embedding-config-form"
          for={@form}
          phx-submit="save_embedding"
          phx-change="validate_embedding"
          class="space-y-5"
        >
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4 items-start">
            <div>
              <.searchable_select
                id="embedding-credential-select"
                name="embedding_config[credential_id]"
                label="Provider / AI credential"
                label_position="block"
                value={to_string(@form[:credential_id].value || "")}
                options={@credential_options}
                empty_label="Select a credential..."
              />
              <.errors field={@form[:credential_id]} />
            </div>
            <div class="space-y-2">
              <fieldset
                disabled={@locked}
                inert={@locked}
                class={[@locked && "opacity-50 pointer-events-none"]}
              >
                <.searchable_select
                  :if={@model_options != []}
                  id="embedding-model-select"
                  name="embedding_config[model]"
                  label="Embedding model"
                  label_position="block"
                  value={@form[:model].value}
                  options={@model_options}
                />
                <Input.input
                  :if={@model_options == []}
                  field={@form[:model]}
                  label="Embedding model"
                  disabled={@locked}
                  phx-debounce="400"
                />
              </fieldset>
              <.errors :if={@model_options != []} field={@form[:model]} />
            </div>
          </div>
          <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
            <Input.input
              field={@form[:dimension]}
              type="number"
              label="Dimension"
              min="1"
              disabled={@locked}
              phx-debounce="400"
            />
            <Input.input
              field={@form[:chunk_min_tokens]}
              type="number"
              label="Chunk Min Tokens"
              min="1"
              phx-debounce="400"
            />
            <Input.input
              field={@form[:chunk_max_tokens]}
              type="number"
              label="Chunk Max Tokens"
              min="1"
              phx-debounce="400"
            />
          </div>
          <p
            :if={not @locked and @form[:dimension].value not in [nil, ""]}
            class="zaq-text-caption"
            style="color: var(--zaq-text-color-body-warning)"
          >
            Changing the model or dimension will permanently delete all chunks and require re-ingestion.
          </p>
          <Button.button
            type="submit"
            variant={if @model_changed, do: :tertiary, else: :primary}
            danger={@model_changed}
          >Save Embedding Settings</Button.button>
        </.form>
        {render_slot(@advanced)}
      </div>
    </CardShell.card_shell>
    """
  end

  attr :field, :any, required: true

  defp errors(assigns) do
    ~H"""
    <p :for={error <- @field.errors} class="zaq-field-error zaq-text-caption">
      {translate_error(error)}
    </p>
    """
  end
end

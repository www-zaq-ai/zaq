defmodule ZaqWeb.Live.BO.System.SystemConfig.ImageToTextTab do
  @moduledoc "Image-to-text model settings for ingestion, using theme-aware BO controls."
  use ZaqWeb, :html
  alias ZaqWeb.Components.DesignSystem.{Button, CardShell, Input}
  import ZaqWeb.Components.SearchableSelect

  attr :form, :any, required: true
  attr :credential_options, :list, required: true
  attr :model_options, :list, required: true

  def panel(assigns) do
    ~H"""
    <CardShell.card_shell id="image-to-text-section">
      <div class="space-y-5">
        <header>
          <h2 class="zaq-text-h3" style="color: var(--zaq-text-color-body-default)">Image to Text</h2>
          <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
            Extract text from images and PDFs during ingestion.
          </p>
        </header>
        <.form
          id="image-to-text-config-form"
          for={@form}
          phx-submit="save_image_to_text"
          phx-change="validate_image_to_text"
          class="space-y-5"
        >
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <.searchable_select
                id="image-to-text-credential-select"
                name="image_to_text_config[credential_id]"
                label="Provider / AI credential"
                label_position="block"
                value={to_string(@form[:credential_id].value || "")}
                options={@credential_options}
                empty_label="Select a credential..."
              />
              <p :for={error <- @form[:credential_id].errors} class="zaq-field-error zaq-text-caption">
                {translate_error(error)}
              </p>
            </div>
            <div>
              <.searchable_select
                :if={@model_options != []}
                id="image-to-text-model-select"
                name="image_to_text_config[model]"
                label="Model"
                label_position="block"
                value={@form[:model].value}
                options={@model_options}
              />
              <Input.input
                :if={@model_options == []}
                field={@form[:model]}
                label="Model"
                phx-debounce="400"
              />
              <p
                :for={error <- @form[:model].errors}
                :if={@model_options != []}
                class="zaq-field-error zaq-text-caption"
              >
                {translate_error(error)}
              </p>
            </div>
          </div>
          <Button.button type="submit">Save Image to Text Settings</Button.button>
        </.form>
      </div>
    </CardShell.card_shell>
    """
  end
end

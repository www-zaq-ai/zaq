defmodule ZaqWeb.Live.BO.System.SystemConfig.ImageToTextTab do
  @moduledoc "Image-to-text model settings for ingestion, using theme-aware BO controls."
  use ZaqWeb, :html
  alias ZaqWeb.Components.DesignSystem.{AIModelSelector, Button, CardShell}

  attr :form, :any, required: true
  attr :credential_options, :list, required: true
  attr :model_options, :list, required: true
  attr :model_catalogs, :map, default: %{}
  attr :stacked, :boolean, default: false

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
          <AIModelSelector.ai_model_selector
            id_prefix="image-to-text"
            form={@form}
            options={@model_options}
            credential_options={@credential_options}
            model_catalogs={@model_catalogs}
            manual_model={@model_options == []}
            layout={if @stacked, do: :stacked, else: :inline}
          />
          <p
            :if={Enum.any?(@model_options, &match?({_, _, "Compatibility unconfirmed"}, &1))}
            id="image-to-text-model-compatibility-note"
            class="zaq-text-caption mt-2"
            style="color: var(--zaq-text-color-body-tertiary)"
          >
            Output capabilities are missing from the catalog; models marked
            “Compatibility unconfirmed” may not support image-to-text.
          </p>
          <Button.button type="submit">Save Image to Text Settings</Button.button>
        </.form>
      </div>
    </CardShell.card_shell>
    """
  end
end

defmodule ZaqWeb.Live.BO.System.SystemConfig.LLMTab do
  @moduledoc "Chat model configuration; retrieval tuning belongs to the RAG tab."
  use ZaqWeb, :html
  alias ZaqWeb.Components.DesignSystem.{AIModelSelector, Button, CardShell, Input}

  attr :form, :any, required: true
  attr :credential_options, :list, required: true
  attr :model_options, :list, required: true
  attr :capabilities, :map, default: %{}
  attr :model_catalogs, :map, default: %{}

  def panel(assigns) do
    ~H"""
    <CardShell.card_shell id="llm-section">
      <div class="space-y-5">
        <header>
          <h2 class="zaq-text-h3" style="color: var(--zaq-text-color-body-default)">LLM</h2>
          <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
            Language model used for chat. Configure retrieval in the RAG tab.
          </p>
        </header>
        <.form
          id="llm-config-form"
          for={@form}
          phx-submit="save_llm"
          phx-change="validate_llm"
          class="space-y-5"
          novalidate
        >
          <Input.input field={@form[:path]} type="hidden" />
          <AIModelSelector.ai_model_selector
            id_prefix="llm"
            form={@form}
            options={@model_options}
            credential_options={@credential_options}
            credential_label="AI Credential"
            model_catalogs={@model_catalogs}
            manual_model={@model_options == []}
            model_required={true}
          />
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <Input.input
              field={@form[:temperature]}
              label="Temperature"
              type="number"
              min="0"
              max="2"
              step="0.1"
              phx-debounce="400"
            />
            <Input.input
              field={@form[:top_p]}
              label="Top-P"
              type="number"
              min="0"
              max="1"
              step="0.05"
              phx-debounce="400"
            />
            <Input.input
              field={@form[:max_context_window]}
              label="Max Context Window (tokens)"
              type="number"
              min="1"
              phx-debounce="400"
            />
          </div>
          <Button.button type="submit">Save LLM Settings</Button.button>
        </.form>
      </div>
    </CardShell.card_shell>
    """
  end
end

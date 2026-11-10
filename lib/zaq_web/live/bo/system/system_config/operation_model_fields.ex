defmodule ZaqWeb.Live.BO.System.SystemConfig.OperationModelFields do
  @moduledoc "Shared credential/model fields for dedicated generation, reranking and decision selections."
  use ZaqWeb, :html
  alias ZaqWeb.Components.DesignSystem.{AIModelSelector, Button}

  attr :kind, :atom, required: true
  attr :form, :any, required: true
  attr :options, :list, required: true
  attr :credential_options, :list, required: true
  attr :title, :string, required: true
  attr :manual_model, :boolean, default: false
  attr :model_catalogs, :map, default: %{}
  attr :change_event, :string, default: "validate_operation_model"
  attr :save_event, :string, default: "save_operation_model"
  attr :model_kind, :string, default: "text-generation"
  attr :stacked, :boolean, default: false

  def selection_form(assigns) do
    ~H"""
    <.form
      id={"#{@kind}-model-form"}
      for={@form}
      phx-change={@change_event}
      phx-submit={@save_event}
      class="space-y-4"
    >
      <input type="hidden" name="kind" value={@kind} />
      <.fields
        id_prefix={to_string(@kind)}
        form={@form}
        options={@options}
        credential_options={@credential_options}
        manual_model={@manual_model}
        stacked={@stacked}
        model_catalogs={@model_catalogs}
        model_empty_label={"Select a #{@model_kind} model..."}
      />
      <p
        :if={@options == [] and not @manual_model and @form[:credential_id].value not in [nil, ""]}
        class="zaq-text-caption"
        style="color: var(--zaq-text-color-body-secondary)"
      >
        No compatible {@model_kind} models. Select a different provider credential.
      </p>
      <Button.button type="submit">Save {@title} Settings</Button.button>
    </.form>
    """
  end

  attr :id_prefix, :string, required: true
  attr :form, :any, required: true
  attr :options, :list, required: true
  attr :credential_options, :list, required: true
  attr :manual_model, :boolean, default: false
  attr :stacked, :boolean, default: false
  attr :model_empty_label, :string, default: "Select a compatible model..."
  attr :model_catalogs, :map, default: %{}

  def fields(assigns) do
    ~H"""
    <AIModelSelector.ai_model_selector
      id_prefix={@id_prefix}
      form={@form}
      options={@options}
      credential_options={[{"Not configured", ""} | @credential_options]}
      manual_model={@manual_model}
      model_catalogs={@model_catalogs}
      model_empty_label={@model_empty_label}
      layout={if @stacked, do: :stacked, else: :inline}
    />
    """
  end
end

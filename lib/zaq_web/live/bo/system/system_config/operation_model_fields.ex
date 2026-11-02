defmodule ZaqWeb.Live.BO.System.SystemConfig.OperationModelFields do
  @moduledoc "Shared credential/model fields for dedicated generation and saved RAG selections."
  use ZaqWeb, :html
  alias ZaqWeb.Components.DesignSystem.{Button, Input}
  import ZaqWeb.Components.SearchableSelect

  attr :kind, :atom, required: true
  attr :form, :any, required: true
  attr :options, :list, required: true
  attr :credential_options, :list, required: true
  attr :title, :string, required: true
  attr :manual_model, :boolean, default: false

  def selection_form(assigns) do
    ~H"""
    <.form
      id={"#{@kind}-model-form"}
      for={@form}
      phx-change="validate_operation_model"
      phx-submit="save_operation_model"
      class="space-y-4"
    >
      <input type="hidden" name="kind" value={@kind} />
      <.fields
        id_prefix={to_string(@kind)}
        form={@form}
        options={@options}
        credential_options={@credential_options}
        manual_model={@manual_model}
        model_empty_label="Select a text-generation model..."
      />
      <p
        :if={@options == [] and not @manual_model and @form[:credential_id].value not in [nil, ""]}
        class="zaq-text-caption"
        style="color: var(--zaq-text-color-body-secondary)"
      >
        No compatible text-generation models. Select a different provider credential.
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

  def fields(assigns) do
    ~H"""
    <div class={
      if @stacked, do: "space-y-4", else: "grid grid-cols-1 md:grid-cols-2 gap-4 items-start"
    }>
      <div>
        <.searchable_select
          id={"#{@id_prefix}-credential-select"}
          name={@form[:credential_id].name}
          label="Provider / AI credential"
          label_position="block"
          value={to_string(@form[:credential_id].value || "")}
          options={[{"Not configured", ""} | @credential_options]}
          empty_label="Select a credential..."
        />
        <p :for={error <- @form[:credential_id].errors} class="zaq-field-error zaq-text-caption">
          {translate_error(error)}
        </p>
      </div>
      <div>
        <.searchable_select
          :if={!@manual_model}
          id={"#{@id_prefix}-model-select"}
          name={@form[:model].name}
          label="Model"
          label_position="block"
          value={@form[:model].value}
          options={@options}
          empty_label={@model_empty_label}
        />
        <Input.input
          :if={@manual_model}
          field={@form[:model]}
          label="Model"
          hint="Enter the model ID for custom endpoints without a model catalog."
        />
        <p
          :for={error <- @form[:model].errors}
          :if={!@manual_model}
          class="zaq-field-error zaq-text-caption"
        >
          {translate_error(error)}
        </p>
      </div>
    </div>
    """
  end
end

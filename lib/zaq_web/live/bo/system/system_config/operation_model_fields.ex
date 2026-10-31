defmodule ZaqWeb.Live.BO.System.SystemConfig.OperationModelFields do
  @moduledoc "Shared dedicated translation/title model selection form."
  use ZaqWeb, :html
  alias ZaqWeb.Components.DesignSystem.{Button, Input}
  import ZaqWeb.Components.SearchableSelect

  attr :kind, :atom, required: true
  attr :form, :any, required: true
  attr :options, :list, required: true
  attr :credential_options, :list, required: true
  attr :title, :string, required: true

  def selection_form(assigns) do
    assigns =
      assign(
        assigns,
        :manual_model,
        assigns.options == [] and assigns.form[:credential_id].value not in [nil, ""]
      )

    ~H"""
    <.form
      id={"#{@kind}-model-form"}
      for={@form}
      phx-change="validate_operation_model"
      phx-submit="save_operation_model"
      class="space-y-4"
    >
      <input type="hidden" name="kind" value={@kind} />
      <div class="grid grid-cols-1 md:grid-cols-2 gap-4 items-start">
        <div>
          <.searchable_select
            id={"#{@kind}-credential-select"}
            name="operation_model_config[credential_id]"
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
            id={"#{@kind}-model-select"}
            name="operation_model_config[model]"
            label="Model"
            label_position="block"
            value={@form[:model].value}
            options={@options}
            empty_label="Select a text-generation model..."
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
      <Button.button type="submit">Save {@title} Settings</Button.button>
    </.form>
    """
  end
end

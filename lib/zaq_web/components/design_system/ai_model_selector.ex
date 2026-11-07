defmodule ZaqWeb.Components.DesignSystem.AIModelSelector do
  @moduledoc """
  Provider credential, model and catalog modalities as one form control group.

  Callers own eligible options, catalog discovery, validation and persistence.
  Catalogs are keyed by string credential ID and contain model maps. An empty
  catalog permits manual model IDs; an ineligible but nonempty catalog does not.
  `manual_model` can override that inference for callers with existing policies.
  Model and modalities always share a row, including in the stacked layout.
  """
  use ZaqWeb, :html

  alias ZaqWeb.Components.DesignSystem.{Input, ModelModalities}
  import ZaqWeb.Components.SearchableSelect

  attr :id_prefix, :string, required: true
  attr :form, :any, required: true
  attr :credential_options, :list, required: true
  attr :options, :list, required: true
  attr :model_catalogs, :map, default: %{}
  attr :manual_model, :any, default: nil
  attr :modalities, :map, default: nil
  attr :modalities_id, :string, default: nil
  attr :credential_id, :string, default: nil
  attr :layout, :atom, values: [:inline, :stacked], default: :inline
  attr :credential_label, :string, default: "Provider / AI credential"
  attr :native_credential, :boolean, default: false
  attr :credential_empty_label, :string, default: "Select a credential..."
  attr :model_label, :string, default: "Model"
  attr :model_empty_label, :string, default: "Select a model..."
  attr :model_disabled, :boolean, default: false
  attr :model_required, :boolean, default: false
  attr :compact, :boolean, default: false

  def ai_model_selector(assigns) do
    credential_id = to_string(assigns.form[:credential_id].value || "")
    catalog = Map.get(assigns.model_catalogs, credential_id)
    model = Enum.find(catalog || [], &(&1.id == assigns.form[:model].value))

    assigns =
      assigns
      |> assign(:manual?, manual?(assigns, credential_id, catalog))
      |> assign(:selected_modalities, assigns.modalities || (model && model.modalities))

    ~H"""
    <div class={["zaq-ai-model-selector", "zaq-ai-model-selector--#{@layout}"]}>
      <div class="zaq-field-row-block zaq-ai-model-provider">
        <.searchable_select
          :if={!@native_credential}
          id={@credential_id || "#{@id_prefix}-credential-select"}
          name={@form[:credential_id].name}
          label={@credential_label}
          label_position="block"
          value={to_string(@form[:credential_id].value || "")}
          options={@credential_options}
          empty_label={@credential_empty_label}
          compact={@compact}
        />
        <label
          :if={@native_credential}
          for={@credential_id || "#{@id_prefix}-credential-select"}
          class="zaq-field-label-uppercase zaq-text-caption"
        >
          {@credential_label}
        </label>
        <select
          :if={@native_credential}
          id={@credential_id || "#{@id_prefix}-credential-select"}
          name={@form[:credential_id].name}
          class="zaq-control-select w-full"
        >
          <option
            :for={{label, value} <- @credential_options}
            value={value}
            selected={to_string(@form[:credential_id].value || "") == to_string(value)}
          >
            {label}
          </option>
        </select>
        <p :for={error <- @form[:credential_id].errors} class="zaq-field-error zaq-text-caption">
          {translate_error(error)}
        </p>
      </div>
      <div class="zaq-ai-model-row">
        <fieldset disabled={@model_disabled} inert={@model_disabled} class="zaq-ai-model-field">
          <.searchable_select
            :if={!@manual?}
            id={"#{@id_prefix}-model-select"}
            name={@form[:model].name}
            label={@model_label}
            label_position="block"
            value={@form[:model].value}
            options={@options}
            empty_label={@model_empty_label}
            compact={@compact}
          />
          <Input.input
            :if={@manual?}
            id={"#{@id_prefix}-model-input"}
            field={@form[:model]}
            label={@model_label}
            required={@model_required}
            disabled={@model_disabled}
            hint="Enter the model ID for custom endpoints without a model catalog."
            phx-debounce="400"
          />
          <p
            :for={error <- @form[:model].errors}
            :if={!@manual?}
            class="zaq-field-error zaq-text-caption"
          >
            {translate_error(error)}
          </p>
        </fieldset>
        <div class="zaq-ai-model-modalities">
          <ModelModalities.model_modalities
            id={@modalities_id || "#{@id_prefix}-modalities"}
            modalities={@selected_modalities}
            selected={@form[:model].value not in [nil, ""]}
          />
        </div>
      </div>
    </div>
    """
  end

  defp manual?(%{manual_model: manual}, _credential_id, _catalog) when is_boolean(manual),
    do: manual

  defp manual?(_assigns, "", _catalog), do: false
  defp manual?(_assigns, _credential_id, catalog) when is_list(catalog), do: catalog == []
  defp manual?(assigns, _credential_id, _catalog), do: assigns.options == []
end

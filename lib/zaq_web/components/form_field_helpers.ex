defmodule ZaqWeb.Components.FormFieldHelpers do
  @moduledoc false

  import Phoenix.Component

  @spec prepare_standard_field(map(), Phoenix.HTML.FormField.t()) :: map()
  def prepare_standard_field(assigns, %Phoenix.HTML.FormField{} = field) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    name =
      case assigns do
        %{name: name} when not is_nil(name) -> name
        _ -> field.name
      end

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &ZaqWeb.CoreComponents.translate_error/1))
    |> assign(:name, name)
    |> assign_new(:value, fn -> field.value end)
  end
end

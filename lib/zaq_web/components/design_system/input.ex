defmodule ZaqWeb.Components.DesignSystem.Input do
  @moduledoc """
  Labelled form input with validation errors.

  Supports text-like HTML inputs, textarea, checkbox, and hidden types.
  For dropdowns use `ZaqWeb.Select.select/1` or `SearchableSelect.searchable_select/1`.
  Pass a `Phoenix.HTML.FormField` via `field` or explicit `name` / `id` / `value` assigns.
  """

  use Phoenix.Component

  import ZaqWeb.CoreComponents, only: [icon: 1]

  alias Phoenix.HTML.Form

  @doc """
  Renders an input with label and error messages.

  ## Examples

      <.input field={@form[:email]} type="email" />
      <.input name="my-input" errors={["oh no!"]} />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"

  attr :multiple, :boolean,
    default: false,
    doc: "when true with field, appends [] to the input name"

  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &ZaqWeb.CoreComponents.translate_error/1))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.field_error :for={msg <- @errors}>{msg}</.field_error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <.input_shell label={@label} errors={@errors} field_id={@id}>
      <:field>
        <textarea
          id={@id}
          name={@name}
          class={text_control_classes(assigns)}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </:field>
    </.input_shell>
    """
  end

  def input(assigns) do
    ~H"""
    <.input_shell label={@label} errors={@errors} field_id={@id}>
      <:field>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={text_control_classes(assigns)}
          {@rest}
        />
      </:field>
    </.input_shell>
    """
  end

  attr :label, :string, default: nil
  attr :errors, :list, default: []
  attr :field_id, :any, default: nil
  slot :field, required: true

  defp input_shell(assigns) do
    ~H"""
    <div class="zaq-field-row-block">
      <label :if={@label} for={@field_id} class="zaq-field-label-uppercase zaq-text-caption">
        {@label}
      </label>
      {render_slot(@field)}
      <.field_error :for={msg <- @errors}>{msg}</.field_error>
    </div>
    """
  end

  slot :inner_block, required: true

  defp field_error(assigns) do
    ~H"""
    <p
      class="mt-1.5 flex gap-2 items-center zaq-text-body-sm"
      style="color: var(--zaq-text-color-body-danger)"
    >
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  defp text_control_classes(assigns) do
    [
      assigns[:class] || "w-full zaq-control-text",
      assigns[:errors] != [] && (assigns[:error_class] || "zaq-border-danger")
    ]
  end
end

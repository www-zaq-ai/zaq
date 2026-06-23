defmodule ZaqWeb.Components.DesignSystem.Checkbox do
  @moduledoc """
  Boolean checkbox for forms (optional label and errors) and interactive UI (bare).

  Use with a `label` for form fields; omit `label` for table row selection and other
  event-driven controls. Pass a `Phoenix.HTML.FormField` via `field` or explicit
  `name` / `id` / `value` assigns.
  """

  use Phoenix.Component

  import ZaqWeb.CoreComponents, only: [icon: 1]

  alias ZaqWeb.Components.FormFieldHelpers

  alias Phoenix.HTML.Form

  @doc """
  Renders a checkbox with optional label and validation errors.

  ## Examples

      <.checkbox field={@form[:notify]} label="Email notifications" />

      <.checkbox
        checked={selected?}
        phx-click="toggle_select"
        phx-value-id={id}
      />
  """
  attr :id, :any, default: nil
  attr :name, :any, default: nil
  attr :label, :string, default: nil
  attr :value, :any

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:notify]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag; derived from value when omitted"

  attr :class, :any, default: nil, doc: "classes for the checkbox input"

  attr :form_hidden, :boolean,
    default: true,
    doc: "when true and name is set, renders a hidden false input for form posts"

  attr :rest, :global,
    include: ~w(disabled form phx-click phx-value-id phx-value-path phx-value-index
                phx-value-right phx-value-role_id phx-target required)

  def checkbox(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> FormFieldHelpers.prepare_standard_field(field)
    |> checkbox()
  end

  def checkbox(assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Form.normalize_value("checkbox", assigns[:value])
      end)

    assigns = assign(assigns, :checkbox_class, checkbox_classes(assigns))

    ~H"""
    <%= if @label do %>
      <div class="zaq-field-row-block">
        <label class="zaq-checkbox-label">
          <.form_hidden_input
            :if={@name && @form_hidden}
            name={@name}
            disabled={@rest[:disabled]}
            form={@rest[:form]}
          />
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@checkbox_class}
            {@rest}
          />
          <span class="zaq-checkbox-label-text">{@label}</span>
        </label>
        <.field_error :for={msg <- @errors}>{msg}</.field_error>
      </div>
    <% else %>
      <span :if={@name && @form_hidden} class="zaq-checkbox-bare">
        <.form_hidden_input
          name={@name}
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={@checkbox_class}
          {@rest}
        />
      </span>
      <input
        :if={!@name || !@form_hidden}
        type="checkbox"
        id={@id}
        name={@name}
        value="true"
        checked={@checked}
        class={@checkbox_class}
        {@rest}
      />
      <.field_error :for={msg <- @errors}>{msg}</.field_error>
    <% end %>
    """
  end

  attr :name, :any, required: true
  attr :disabled, :boolean, default: false
  attr :form, :any, default: nil

  defp form_hidden_input(assigns) do
    ~H"""
    <input type="hidden" name={@name} value="false" disabled={@disabled} form={@form} />
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

  defp checkbox_classes(assigns) do
    assigns[:class] || "zaq-bo-checkbox zaq-focus-visible"
  end
end

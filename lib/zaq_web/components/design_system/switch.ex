defmodule ZaqWeb.Components.DesignSystem.Switch do
  @moduledoc """
  Boolean pill switch for forms.

  ## Layouts

  * `:inline` — switch and label in one row (e.g. sovereign credential on AI credentials).
  * `:setting_row` — title and optional description on the left, switch on the right (e.g. telemetry).

  ## Modes

  * `:boolean` — hidden `off_value` input plus named checkbox posting `on_value` when checked.
  * `:enum` — hidden input carries the current string value; checkbox is UI-only (e.g. MCP status).

  The track is 64×32px (layout scale tokens). When on, the knob slides right and shows a check icon.

  ## Examples

      <.switch field={@form[:sovereign]} label="Sovereign credential" />

      <.switch
        field={@form[:capture_infra_metrics]}
        layout={:setting_row}
        label="Capture infra metrics"
        description="Collect Phoenix request, Repo query, and Oban runtime metrics."
      />

      <.switch
        name="mcp_endpoint[status]"
        value={@form[:status].value}
        mode={:enum}
        on_value="enabled"
        off_value="disabled"
        on_label="Enabled"
        off_label="Disabled"
        phx-click={toggle_status_js}
      />
  """

  use Phoenix.Component

  import ZaqWeb.CoreComponents, only: [icon: 1]

  alias Phoenix.HTML.Form
  alias ZaqWeb.Components.FormFieldHelpers

  attr :id, :any, default: nil
  attr :name, :any, default: nil
  attr :label, :string, default: nil
  attr :description, :string, default: nil
  attr :value, :any

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:sovereign]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "checked state; derived from value when omitted"

  attr :layout, :atom, default: :inline, values: [:inline, :setting_row]

  attr :mode, :atom,
    default: :boolean,
    values: [:boolean, :enum],
    doc: ":boolean for true/false fields; :enum when hidden input stores string values"

  attr :on_value, :string, default: "true", doc: "value when switch is on"

  attr :off_value, :string,
    default: "false",
    doc: "hidden value when off (:boolean) or unchecked (:enum)"

  attr :on_label, :string, default: nil, doc: "inline label when on (:enum mode)"
  attr :off_label, :string, default: nil, doc: "inline label when off (:enum mode)"

  attr :form_hidden, :boolean,
    default: true,
    doc: "when true and name is set, renders a hidden input for form posts"

  attr :class, :any, default: nil

  attr :rest, :global, include: ~w(disabled form phx-click phx-target required)

  def switch(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> FormFieldHelpers.prepare_standard_field(field)
    |> switch()
  end

  def switch(assigns) do
    assigns = assign_new(assigns, :checked, &derive_checked/1)

    assigns =
      assigns
      |> assign(:hidden_value, hidden_value(assigns))
      |> assign(:checkbox_name, checkbox_name(assigns))
      |> assign(:display_label, display_label(assigns))
      |> assign(:switch_aria_label, switch_aria_label(assigns))
      |> then(fn a -> assign(a, :show_inline_label, show_inline_label?(a)) end)

    ~H"""
    <%= if @layout == :setting_row do %>
      <div class={["zaq-switch-setting-row", @class]}>
        <div :if={@label || @description} class="zaq-switch-setting-copy">
          <p :if={@label} class="zaq-switch-setting-title zaq-text-body-sm">{@label}</p>
          <p :if={@description} class="zaq-switch-setting-description zaq-text-body-sm">
            {@description}
          </p>
        </div>
        <label class="zaq-switch-control">
          <.switch_inputs
            id={@id}
            name={@name}
            checkbox_name={@checkbox_name}
            hidden_value={@hidden_value}
            on_value={@on_value}
            checked={@checked}
            form_hidden={@form_hidden}
            aria_label={@switch_aria_label}
            disabled={@rest[:disabled]}
            form={@rest[:form]}
            phx_click={Map.get(@rest, :"phx-click")}
            phx_target={Map.get(@rest, :"phx-target")}
            required={@rest[:required]}
          />
        </label>
      </div>
      <.field_error :for={msg <- @errors}>{msg}</.field_error>
    <% else %>
      <div class={["zaq-field-row-block", @class]}>
        <label class="zaq-switch-label">
          <.switch_inputs
            id={@id}
            name={@name}
            checkbox_name={@checkbox_name}
            hidden_value={@hidden_value}
            on_value={@on_value}
            checked={@checked}
            form_hidden={@form_hidden}
            aria_label={@switch_aria_label}
            disabled={@rest[:disabled]}
            form={@rest[:form]}
            phx_click={Map.get(@rest, :"phx-click")}
            phx_target={Map.get(@rest, :"phx-target")}
            required={@rest[:required]}
          />
          <span :if={@show_inline_label} class="zaq-switch-text zaq-text-body-sm">
            {@display_label}
          </span>
        </label>
        <.field_error :for={msg <- @errors}>{msg}</.field_error>
      </div>
    <% end %>
    """
  end

  attr :id, :any, default: nil
  attr :name, :any, default: nil
  attr :checkbox_name, :any, default: nil
  attr :hidden_value, :string, required: true
  attr :on_value, :string, required: true
  attr :checked, :boolean, required: true
  attr :form_hidden, :boolean, required: true
  attr :aria_label, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :form, :any, default: nil
  attr :phx_click, :any, default: nil
  attr :phx_target, :any, default: nil
  attr :required, :boolean, default: false

  defp switch_inputs(assigns) do
    ~H"""
    <input
      :if={@name && @form_hidden}
      type="hidden"
      name={@name}
      value={@hidden_value}
      disabled={@disabled}
      form={@form}
    />
    <input
      type="checkbox"
      id={@id}
      name={@checkbox_name}
      value={@on_value}
      checked={@checked}
      role="switch"
      aria-checked={to_string(@checked)}
      aria-label={@aria_label}
      class="zaq-switch-input zaq-focus-visible"
      disabled={@disabled}
      form={@form}
      phx-click={@phx_click}
      phx-target={@phx_target}
      required={@required}
    />
    <span class="zaq-switch-track" aria-hidden="true">
      <span class="zaq-switch-knob">
        <.icon name="hero-check" class="zaq-switch-knob-icon" />
      </span>
    </span>
    """
  end

  slot :inner_block, required: true

  defp field_error(assigns) do
    ~H"""
    <p class="zaq-field-error zaq-text-body-sm" style="color: var(--zaq-text-color-body-danger)">
      <.icon name="hero-exclamation-circle" class="zaq-icon-sm" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  defp derive_checked(assigns) do
    case assigns do
      %{checked: checked} when is_boolean(checked) ->
        checked

      %{mode: :enum} ->
        enum_checked?(assigns)

      _ ->
        boolean_checked?(assigns[:value])
    end
  end

  defp boolean_checked?(value), do: Form.normalize_value("checkbox", value)

  defp enum_checked?(assigns) do
    to_string(assigns[:value] || "") == assigns[:on_value]
  end

  defp hidden_value(%{mode: :enum, checked: checked, on_value: on_value, off_value: off_value}) do
    if checked, do: on_value, else: off_value
  end

  defp hidden_value(%{off_value: off_value}), do: off_value

  defp checkbox_name(%{mode: :enum}), do: nil
  defp checkbox_name(%{name: name}), do: name

  defp display_label(%{mode: :enum, checked: checked, on_label: on_label, off_label: off_label})
       when is_binary(on_label) and is_binary(off_label) do
    if checked, do: on_label, else: off_label
  end

  defp display_label(%{label: label}), do: label

  defp switch_aria_label(%{label: label}) when is_binary(label), do: label

  defp switch_aria_label(%{mode: :enum, checked: true, on_label: label}) when is_binary(label),
    do: label

  defp switch_aria_label(%{mode: :enum, off_label: label}) when is_binary(label), do: label

  defp switch_aria_label(_), do: nil

  defp show_inline_label?(%{layout: :inline, display_label: label}) when is_binary(label),
    do: true

  defp show_inline_label?(_), do: false
end

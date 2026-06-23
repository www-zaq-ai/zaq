defmodule ZaqWeb.Components.DesignSystem.SecretInput do
  @moduledoc """
  Password or token input with a built-in show/hide toggle.

  Intended for sensitive fields where users may need to reveal the value briefly.
  For other form controls use `ZaqWeb.Components.DesignSystem.Input`.
  """

  use Phoenix.Component

  import ZaqWeb.CoreComponents, only: [icon: 1]

  alias ZaqWeb.Components.FormFieldHelpers
  alias ZaqWeb.Components.FormInputIds

  @doc """
  Renders a secret input with built-in show/hide toggle.

  ## Examples

      <.secret_input field={@form[:password]} label="Password" />

      <.secret_input
        id="login-password"
        name="password"
        value={@form[:password].value}
        placeholder="••••••••"
        required
      />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:password]"

  attr :errors, :list, default: []
  attr :input_class, :any, default: nil
  attr :error_class, :any, default: nil
  attr :button_class, :any, default: nil
  attr :wrapper_class, :any, default: nil

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step phx-debounce)

  def secret_input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> FormFieldHelpers.prepare_standard_field(field)
    |> secret_input()
  end

  def secret_input(assigns) do
    assigns =
      if is_binary(assigns[:id]) and assigns[:id] != "" do
        assigns
      else
        assign(assigns, :id, FormInputIds.secret_input_id(assigns[:name]))
      end

    ~H"""
    <div class="zaq-field-row-block">
      <label :if={@label} for={@id} class="zaq-field-label-uppercase zaq-text-caption">
        {@label}
      </label>
      <div class={@wrapper_class || "zaq-control-secret-wrap"}>
        <input
          type="password"
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value("password", @value)}
          class={secret_input_classes(assigns)}
          {@rest}
        />
        <button
          type="button"
          onclick={
            "var i=document.getElementById('#{@id}');i.type=i.type==='password'?'text':'password';this.querySelector('.eye-on').classList.toggle('hidden');this.querySelector('.eye-off').classList.toggle('hidden');"
          }
          class={@button_class || "zaq-control-secret-toggle"}
          tabindex="-1"
          aria-label="Show or hide value"
        >
          <.icon name="hero-eye" class="eye-on zaq-control-secret-toggle-icon" />
          <.icon name="hero-eye-slash" class="eye-off hidden zaq-control-secret-toggle-icon" />
        </button>
      </div>
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

  defp secret_input_classes(assigns) do
    [
      assigns[:input_class] || "w-full zaq-control-text zaq-control-secret",
      assigns[:errors] != [] && (assigns[:error_class] || "zaq-border-danger")
    ]
  end
end

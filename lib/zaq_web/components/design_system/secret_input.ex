defmodule ZaqWeb.Components.DesignSystem.SecretInput do
  @moduledoc """
  Password or token input with a built-in show/hide toggle.

  Extracted from `ZaqWeb.CoreComponents.secret_input/1`. Intended for sensitive
  fields where users may need to reveal the value briefly.
  """

  use Phoenix.Component

  import ZaqWeb.CoreComponents, only: [icon: 1]

  alias ZaqWeb.Components.FormInputIds

  @doc """
  Renders a secret input with built-in show/hide toggle.

  ## Examples

      <.secret_input field={@form[:password]} />

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
  attr :button_class, :any, default: nil
  attr :wrapper_class, :any, default: nil

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step phx-debounce)

  def secret_input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil)
    |> assign(:errors, Enum.map(errors, &ZaqWeb.CoreComponents.translate_error/1))
    |> assign_new(:name, fn -> field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> assign_new(:id, fn -> field.id end)
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
    <div class={@wrapper_class || "relative"}>
      <input
        type="password"
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value("password", @value)}
        class={@input_class || "w-full input pr-11"}
        {@rest}
      />
      <button
        type="button"
        onclick={
          "var i=document.getElementById('#{@id}');i.type=i.type==='password'?'text':'password';this.querySelector('.eye-on').classList.toggle('hidden');this.querySelector('.eye-off').classList.toggle('hidden');"
        }
        class={
          @button_class ||
            "absolute right-3 top-1/2 -translate-y-1/2 text-black/30 hover:text-black/60 transition-colors focus:outline-none"
        }
        tabindex="-1"
      >
        <svg
          class="eye-on w-4 h-4"
          xmlns="http://www.w3.org/2000/svg"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
        >
          <path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7z" />
          <circle cx="12" cy="12" r="3" />
        </svg>
        <svg
          class="eye-off hidden w-4 h-4"
          xmlns="http://www.w3.org/2000/svg"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
        >
          <path d="M17.94 17.94A10.07 10.07 0 0112 20c-7 0-11-8-11-8a18.45 18.45 0 015.06-5.94M9.9 4.24A9.12 9.12 0 0112 4c7 0 11 8 11 8a18.5 18.5 0 01-2.16 3.19m-6.72-1.07a3 3 0 11-4.24-4.24" />
          <line x1="1" y1="1" x2="23" y2="23" />
        </svg>
      </button>
    </div>
    <.field_error :for={msg <- @errors}>{msg}</.field_error>
    """
  end

  slot :inner_block, required: true

  defp field_error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end
end

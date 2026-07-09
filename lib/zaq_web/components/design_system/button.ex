defmodule ZaqWeb.Components.DesignSystem.Button do
  @moduledoc """
  BO action button — composes `.zaq-btn*` classes from `assets/css/btn.css`.

  Variants: `:primary`, `:secondary`, `:ghost`, `:tertiary`.
  Shapes: `:default` (`.zaq-btn`) or `:pill` (`.zaq-btn-pill`, secondary chips).

  Optional `icon` with `icon_position` (`:left` default, `:right`).
  Set `icon_only` for square icon buttons — pass `aria-label` via attributes.

  Tertiary-only modifiers: `active` (`.zaq-btn-tertiary--active`), `danger` (`.zaq-btn-danger`).

  Set `loading` to attach `phx-hook="LoadingActionButton"` and swap label for a spinner
  + `loading_label` while a `phx-click` is in flight (any variant).

  Navigation: pass `navigate`, `href`, or `patch` to render `<.link>` styled as a button.
  Loading is ignored on link buttons.
  """

  use Phoenix.Component

  import ZaqWeb.CoreComponents, only: [icon: 1]

  attr :variant, :atom,
    default: :primary,
    values: [:primary, :secondary, :ghost, :tertiary]

  attr :shape, :atom, default: :default, values: [:default, :pill]

  attr :icon, :string, default: nil, doc: "Optional Heroicon name (e.g. `hero-trash`)."

  attr :icon_position, :atom,
    default: :left,
    values: [:left, :right],
    doc: "Icon placement when `icon` is set and `icon_only` is false."

  attr :icon_only, :boolean,
    default: false,
    doc: "Square icon button — adds `.zaq-btn-icon`; requires `icon` and `aria-label`."

  attr :active, :boolean,
    default: false,
    doc: "Tertiary active chip — adds `.zaq-btn-tertiary--active`."

  attr :danger, :boolean,
    default: false,
    doc: "Destructive tertiary — adds `.zaq-btn-danger` (compose with `variant={:tertiary}`)."

  attr :loading, :boolean,
    default: false,
    doc: "When true, enables click-loading spinner via `LoadingActionButton` hook."

  attr :loading_label, :string, default: "Loading..."

  attr :navigate, :string, default: nil
  attr :href, :string, default: nil
  attr :patch, :string, default: nil

  attr :type, :string, default: "button", doc: "Button `type` when not rendered as a link."

  attr :class, :any, default: nil, doc: "Layout utilities only — no color overrides."

  attr :rest, :global,
    include:
      ~w(disabled id phx-click phx-value-id phx-value-predefined_id title aria-label data-testid name value form)

  slot :inner_block

  def button(assigns) do
    assigns =
      assigns
      |> assign(:icon, normalize_icon(assigns))
      |> assign(:icon_position, normalize_icon_position(assigns.icon_position))
      |> assign(:variant, normalize_variant(assigns.variant))

    link? = link?(assigns)
    use_loading_ui? = assigns.loading && !link?

    assigns =
      assigns
      |> assign(:link?, link?)
      |> assign(:use_loading_ui?, use_loading_ui?)
      |> assign(:link_attrs, link_attrs(assigns))
      |> then(fn a -> assign(a, :shell_class, shell_class(a)) end)

    ~H"""
    <%= if @link? do %>
      <.link class={@shell_class} {@link_attrs} {@rest}>
        {render_button_content(assigns)}
      </.link>
    <% else %>
      <button
        type={@type}
        class={@shell_class}
        phx-hook={@use_loading_ui? && "LoadingActionButton"}
        {@rest}
      >
        {render_button_content(assigns)}
      </button>
    <% end %>
    """
  end

  attr :name, :string, required: true

  defp button_icon(assigns) do
    ~H"""
    <span class="inline-flex shrink-0 items-center">
      <.icon name={@name} class="zaq-icon-sm" />
    </span>
    """
  end

  defp render_button_content(%{use_loading_ui?: true} = assigns) do
    assigns = assign(assigns, :inner_content, inner_content(assigns))

    ~H"""
    <span class="zaq-btn__label inline-flex items-center">
      {@inner_content}
    </span>
    <span
      class="zaq-btn__loading hidden inline-flex items-center"
      style="gap: var(--zaq-scale-8);"
    >
      <.icon name="hero-arrow-path" class="zaq-icon-sm animate-spin" />
      <span :if={show_loading_label?(assigns)}>{@loading_label}</span>
    </span>
    """
  end

  defp render_button_content(assigns) do
    inner_content(assigns)
  end

  defp inner_content(assigns) do
    ~H"""
    <.button_icon :if={show_icon_left?(assigns)} name={@icon} />
    <span :if={not @icon_only}>{render_slot(@inner_block)}</span>
    <.button_icon :if={show_icon_right?(assigns)} name={@icon} />
    """
  end

  defp show_icon_left?(assigns) do
    icon?(assigns) and (assigns.icon_only or assigns.icon_position == :left)
  end

  defp show_icon_right?(assigns) do
    icon?(assigns) and not assigns.icon_only and assigns.icon_position == :right
  end

  defp icon?(assigns), do: is_binary(assigns.icon) and assigns.icon != ""

  defp show_loading_label?(assigns) do
    not assigns.icon_only or assigns.loading_label != ""
  end

  defp shell_class(assigns) do
    [
      shape_class(assigns.shape),
      variant_class(assigns.variant),
      icon_only_class(assigns),
      tertiary_active_class(assigns),
      danger_class(assigns),
      typography_class(assigns),
      loading_toggle_classes(Map.get(assigns, :use_loading_ui?, false)),
      assigns.class
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp shape_class(:pill), do: "zaq-btn-pill"
  defp shape_class(:default), do: "zaq-btn"

  defp variant_class(variant), do: "zaq-btn-#{variant}"

  defp icon_only_class(%{icon_only: true}), do: "zaq-btn-icon"
  defp icon_only_class(_), do: nil

  defp tertiary_active_class(%{variant: :tertiary, active: true}), do: "zaq-btn-tertiary--active"
  defp tertiary_active_class(_), do: nil

  defp danger_class(%{danger: true}), do: "zaq-btn-danger"
  defp danger_class(_), do: nil

  defp typography_class(%{icon_only: true}), do: nil
  defp typography_class(_), do: "zaq-btn-text_label-default"

  defp loading_toggle_classes(true) do
    [
      "[&.phx-click-loading_.zaq-btn__label]:hidden",
      "[&.phx-click-loading_.zaq-btn__loading]:inline-flex"
    ]
  end

  defp loading_toggle_classes(false), do: nil

  defp link?(assigns) do
    link_attrs(assigns) != %{}
  end

  defp link_attrs(%{navigate: nav}) when is_binary(nav) and nav != "", do: %{navigate: nav}
  defp link_attrs(%{href: href}) when is_binary(href) and href != "", do: %{href: href}
  defp link_attrs(%{patch: patch}) when is_binary(patch) and patch != "", do: %{patch: patch}
  defp link_attrs(_), do: %{}

  defp normalize_icon_position(position) when position in [:left, :right], do: position
  defp normalize_icon_position("left"), do: :left
  defp normalize_icon_position("right"), do: :right

  defp normalize_variant(variant) when variant in [:primary, :secondary, :ghost, :tertiary],
    do: variant

  defp normalize_variant("primary"), do: :primary
  defp normalize_variant("secondary"), do: :secondary
  defp normalize_variant("ghost"), do: :ghost
  defp normalize_variant("tertiary"), do: :tertiary

  defp normalize_icon(assigns) do
    case assigns[:icon] || Map.get(assigns, "icon") do
      icon when is_binary(icon) and icon != "" -> icon
      _ -> nil
    end
  end
end

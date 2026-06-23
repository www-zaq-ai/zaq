defmodule ZaqWeb.Components.DesignSystem.Link do
  @moduledoc """
  BO underline navigation link — decoration on the label only (icon excluded).

  Set `destination` to the target path. Use `external: true` for plain `href` links.
  Sizes: `:default` (`.zaq-text-body`) and `:sm` (`.zaq-text-body-sm`).
  Optional `icon` with `icon_position` (`:left` default, `:right`).

  Color: `tone` — `:default` (inherit from parent) or `:accent` (`--zaq-text-color-body-accent`).
  No other color modes; do not pass color utilities via `class`.

  **Styles:** `.zaq-link`, `.zaq-link-underline` in `styles.css`.
  """

  use Phoenix.Component

  import ZaqWeb.CoreComponents, only: [icon: 1]

  attr :destination, :string, required: true, doc: "Target path or URL."

  attr :external, :boolean,
    default: false,
    doc: "When true, renders `href` instead of LiveView `navigate`."

  attr :size, :atom, default: :default, values: [:default, :sm]

  attr :tone, :atom,
    default: :default,
    values: [:default, :accent],
    doc: "`:default` inherits color from parent; `:accent` uses `--zaq-text-color-body-accent`."

  attr :icon, :string, default: nil, doc: "Optional Heroicon name (e.g. `hero-arrow-right`)."

  attr :icon_position, :atom,
    default: :left,
    values: [:left, :right],
    doc: "Icon placement when `icon` is set. Underline stays on the label only."

  attr :id, :string, default: nil
  attr :class, :any, default: nil

  attr :rest, :global, include: ~w(data-testid aria-label patch)

  slot :inner_block, required: true

  def nav_link(assigns) do
    tone = normalize_tone(assigns.tone)

    assigns =
      assigns
      |> assign(:tone, tone)
      |> assign(:icon_position, normalize_icon_position(assigns.icon_position))
      |> assign(:shell_class, shell_class(tone))
      |> assign(:label_class, label_class(assigns.size))
      |> assign(:destination_attrs, destination_attrs(assigns.external, assigns.destination))

    ~H"""
    <.link id={@id} class={[Enum.join(@shell_class, " "), @class]} {@destination_attrs} {@rest}>
      <.link_icon :if={@icon && @icon_position == :left} name={@icon} />
      <span class={@label_class}>
        {render_slot(@inner_block)}
      </span>
      <.link_icon :if={@icon && @icon_position == :right} name={@icon} />
    </.link>
    """
  end

  attr :name, :string, required: true

  defp link_icon(assigns) do
    ~H"""
    <span class="zaq-link__icon">
      <.icon name={@name} class="zaq-icon-sm" />
    </span>
    """
  end

  defp shell_class(:default), do: ["zaq-link", "zaq-focus-visible"]
  defp shell_class(:accent), do: ["zaq-link", "zaq-link--accent", "zaq-focus-visible"]

  defp label_class(size) do
    [text_size_class(size), "zaq-link__label", "zaq-link-underline"]
  end

  defp text_size_class(:default), do: "zaq-text-body"
  defp text_size_class(:sm), do: "zaq-text-body-sm"

  defp destination_attrs(true, destination), do: %{href: destination}
  defp destination_attrs(false, destination), do: %{navigate: destination}

  defp normalize_icon_position(position) when position in [:left, :right], do: position
  defp normalize_icon_position("left"), do: :left
  defp normalize_icon_position("right"), do: :right

  defp normalize_tone(tone) when tone in [:default, :accent], do: tone
  defp normalize_tone("default"), do: :default
  defp normalize_tone("accent"), do: :accent
end

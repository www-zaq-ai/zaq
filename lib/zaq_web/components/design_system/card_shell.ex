defmodule ZaqWeb.Components.DesignSystem.CardShell do
  @moduledoc """
  Shared BO card shell — surface tokens, optional whole-card navigation, and optional
  secondary text link below the card.

  * **`variant={:default}`** — use with `primary_link` for interactive cards; the inner
    surface gets `.zaq-card-hover` as a direct child of the link (accent border on hover).
  * **`variant={:muted}`** — non-navigable; no hover affordance (e.g. “Coming soon”).
  * **`footer_link`** — when set alongside `primary_link`, the primary link wraps header and
    body only; a ghost `DesignSystem.Button` in the footer uses the same destination (avoids
    nested anchors). Ingress or other `phx-click` controls stay in slots.

  Slots: `header`, inner block (body), `footer`.
  """

  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.Button, only: [button: 1]
  import ZaqWeb.Components.DesignSystem.Link, only: [nav_link: 1]

  attr :id, :string,
    required: true,
    doc: "DOM identity assigned once to the card surface or its whole-card navigation link."

  attr :as, :atom,
    default: :article,
    values: [:article, :div],
    doc: "Root surface element when not wrapped in a primary link."

  attr :variant, :atom,
    default: :default,
    values: [:default, :muted],
    doc: "`:muted` — no primary navigation and no hover shell."

  attr :primary_link, :map,
    default: nil,
    doc:
      "Optional `%{destination:, id:, external:}` — wraps header/body (and footer when no `footer_link`)."

  attr :secondary_link, :map,
    default: nil,
    doc:
      "Optional `%{destination:, label:, id:, tone:, size:, icon:, icon_position:, external:}` below the card."

  attr :footer_link, :map,
    default: nil,
    doc:
      "Optional footer CTA `%{destination:, label:, id:, external:, icon:, icon_position:, variant:}`; requires `primary_link`."

  attr :class, :any,
    default: nil,
    doc: "Extra classes on the card surface (layout or interim legacy chrome)."

  attr :style, :string, default: nil

  slot :header
  slot :inner_block, required: true
  slot :footer

  def card_shell(assigns) do
    resolved_primary = normalize_primary_link(assigns.primary_link)

    assigns =
      assigns
      |> assign(:resolved_primary, resolved_primary)
      |> assign(:resolved_secondary, normalize_secondary_link(assigns.secondary_link))
      |> assign(:resolved_footer, normalize_footer_link(assigns.footer_link, resolved_primary))
      |> assign(:interactive?, interactive?(assigns.variant, assigns.primary_link))
      |> assign(:split_footer?, split_footer?(assigns))

    ~H"""
    <div :if={@resolved_secondary} class="space-y-2">
      <.card_shell_surface
        id={@id}
        as={@as}
        class={@class}
        style={@style}
        interactive?={@interactive?}
        primary={@resolved_primary}
        footer_link={@resolved_footer}
        split_footer?={@split_footer?}
      >
        <:header>{render_slot(@header)}</:header>
        <:body>{render_slot(@inner_block)}</:body>
        <:footer>{render_slot(@footer)}</:footer>
      </.card_shell_surface>
      <.card_shell_secondary_link link={@resolved_secondary} />
    </div>
    <.card_shell_surface
      :if={!@resolved_secondary}
      id={@id}
      as={@as}
      class={@class}
      style={@style}
      interactive?={@interactive?}
      primary={@resolved_primary}
      footer_link={@resolved_footer}
      split_footer?={@split_footer?}
    >
      <:header>{render_slot(@header)}</:header>
      <:body>{render_slot(@inner_block)}</:body>
      <:footer>{render_slot(@footer)}</:footer>
    </.card_shell_surface>
    """
  end

  attr :id, :string, required: true
  attr :as, :atom, required: true
  attr :class, :any, default: nil
  attr :style, :string, default: nil
  attr :interactive?, :boolean, required: true
  attr :primary, :map, default: nil
  attr :footer_link, :map, default: nil
  attr :split_footer?, :boolean, required: true
  slot :header
  slot :body, required: true
  slot :footer

  defp card_shell_surface(assigns) do
    assigns =
      assign(
        assigns,
        :surface_class,
        surface_classes(assigns.interactive?, assigns.split_footer?, assigns.class)
      )

    ~H"""
    <%= cond do %>
      <% @split_footer? and @primary -> %>
        <.card_root id={@id} as={@as} class={@surface_class} style={@style}>
          <.link
            id={split_link_dom_id(@primary, @id)}
            class="group block min-h-0 flex-1 flex flex-col"
            {primary_destination_attrs(@primary)}
          >
            <div class="flex min-h-0 flex-1 flex-col">
              <.card_shell_regions header={@header} body={@body} footer={[]} />
            </div>
          </.link>
          <div :if={@footer != [] or @footer_link} class="mt-auto">
            {render_slot(@footer)}
            <.card_shell_footer_button :if={@footer_link} link={@footer_link} />
          </div>
        </.card_root>
      <% @interactive? and @primary -> %>
        <.link
          id={link_dom_id(@primary, @id)}
          class="group block"
          {primary_destination_attrs(@primary)}
        >
          <.card_root
            id={surface_dom_id(@primary, @id)}
            as={@as}
            class={@surface_class}
            style={@style}
          >
            <.card_shell_regions header={@header} body={@body} footer={@footer} />
          </.card_root>
        </.link>
      <% true -> %>
        <.card_root id={@id} as={@as} class={@surface_class} style={@style}>
          <.card_shell_regions header={@header} body={@body} footer={@footer} />
        </.card_root>
    <% end %>
    """
  end

  attr :header, :any
  attr :body, :any, required: true
  attr :footer, :any, default: []

  defp card_shell_regions(assigns) do
    ~H"""
    <div :if={@header != []} class="contents">{render_slot(@header)}</div>
    <div class="contents">{render_slot(@body)}</div>
    <div :if={@footer != []} class="contents">{render_slot(@footer)}</div>
    """
  end

  attr :id, :string, required: true
  attr :as, :atom, required: true
  attr :class, :any, required: true
  attr :style, :string, default: nil
  slot :inner_block, required: true

  defp card_root(assigns) do
    assigns = assign(assigns, :tag, if(assigns.as == :article, do: "article", else: "div"))

    ~H"""
    <%= if @tag == "article" do %>
      <article class={@class} style={@style} id={@id}>
        {render_slot(@inner_block)}
      </article>
    <% else %>
      <div class={@class} style={@style} id={@id}>
        {render_slot(@inner_block)}
      </div>
    <% end %>
    """
  end

  attr :link, :map, required: true

  defp card_shell_footer_button(assigns) do
    ~H"""
    <.button
      id={@link.id}
      variant={@link.variant}
      icon={@link.icon}
      icon_position={@link.icon_position}
      navigate={if(@link.external, do: nil, else: @link.destination)}
      href={if(@link.external, do: @link.destination, else: nil)}
      class="mt-auto w-fit"
    >
      {@link.label}
    </.button>
    """
  end

  attr :link, :map, required: true

  defp card_shell_secondary_link(assigns) do
    ~H"""
    <.nav_link
      id={@link.id}
      destination={@link.destination}
      external={@link.external}
      tone={@link.tone}
      size={@link.size}
      icon={@link.icon}
      icon_position={@link.icon_position}
    >
      {@link.label}
    </.nav_link>
    """
  end

  defp surface_classes(interactive?, split_footer?, extra_class) do
    base =
      [
        "zaq-card-default zaq-border-default flex flex-col",
        interactive? && !split_footer? && "zaq-card-hover",
        split_footer? && "min-h-0 zaq-card-hover"
      ]

    [base, extra_class]
  end

  defp interactive?(:muted, _primary), do: false
  defp interactive?(_, nil), do: false
  defp interactive?(_, _primary), do: true

  defp split_footer?(%{footer_link: nil}), do: false
  defp split_footer?(%{footer_link: _}), do: true

  defp normalize_primary_link(nil), do: nil

  defp normalize_primary_link(link) do
    destination = map_get(link, :destination)

    if blank_meta_value?(destination) do
      nil
    else
      %{
        destination: destination,
        id: map_get(link, :id),
        external: map_get(link, :external) || false
      }
    end
  end

  defp normalize_secondary_link(nil), do: nil

  defp normalize_secondary_link(link) do
    destination = map_get(link, :destination)
    label = map_get(link, :label)

    if blank_meta_value?(destination) or blank_meta_value?(label) do
      nil
    else
      %{
        destination: destination,
        label: label,
        id: map_get(link, :id),
        external: map_get(link, :external) || false,
        tone: map_get(link, :tone) || :accent,
        size: map_get(link, :size) || :sm,
        icon: map_get(link, :icon) || "hero-arrow-right",
        icon_position: map_get(link, :icon_position) || :right
      }
    end
  end

  defp normalize_footer_link(nil, _primary), do: nil

  defp normalize_footer_link(link, primary) when is_map(primary) do
    destination = map_get(link, :destination) || map_get(primary, :destination)
    label = map_get(link, :label)

    if blank_meta_value?(destination) or blank_meta_value?(label) do
      nil
    else
      %{
        destination: destination,
        label: label,
        id: map_get(link, :id),
        external: map_get(link, :external) || map_get(primary, :external) || false,
        variant: map_get(link, :variant) || :ghost,
        icon: map_get(link, :icon) || "hero-arrow-right",
        icon_position: map_get(link, :icon_position) || :right
      }
    end
  end

  defp normalize_footer_link(_link, _primary), do: nil

  defp primary_destination_attrs(%{external: true, destination: destination}),
    do: %{href: destination}

  defp primary_destination_attrs(%{destination: destination}), do: %{navigate: destination}

  defp blank_meta_value?(value) when value in [nil, ""], do: true
  defp blank_meta_value?(_value), do: false

  defp map_get(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp link_dom_id(%{id: id}, _surface_id) when is_binary(id) and id != "", do: id
  defp link_dom_id(_primary, surface_id), do: surface_id

  defp split_link_dom_id(%{id: id}, surface_id)
       when is_binary(id) and id != "" and id != surface_id,
       do: id

  defp split_link_dom_id(_primary, _surface_id), do: nil

  defp surface_dom_id(%{id: id}, surface_id) when is_binary(id) and id != "" and id != surface_id,
    do: surface_id

  defp surface_dom_id(%{id: id}, surface_id) when is_binary(id) and id == surface_id, do: nil
  defp surface_dom_id(_primary, _surface_id), do: nil
end

defmodule ZaqWeb.Components.DesignSystem.MetricCard do
  @moduledoc """
  BO KPI metric card — label, value, optional unit/trend, and metadata footer.

  Optional navigation:

  * **`primary_link`** — map `%{destination:, id:, external:}` wrapping the card in a
    block link (`group block`). When omitted and `card` is a `%ScalarPayload{}` with
    `runtime.href`, the primary link is derived from the payload.
  * **`secondary_link`** — map `%{destination:, label:, id:, tone:, size:, icon:,
    icon_position:, external:}` rendering `DesignSystem.Link.nav_link/1` below the card.

  Display metadata comes from `display` / flat attrs; `runtime` metadata is never rendered
  on the card surface (only used for primary-link auto-fill).
  """

  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.Link, only: [nav_link: 1]

  alias Zaq.Engine.Telemetry.Contracts.DisplayMeta
  alias Zaq.Engine.Telemetry.Contracts.Payloads.ScalarPayload
  alias ZaqWeb.Helpers.TelemetryFormat

  attr :id, :string, required: true, doc: "Id on the card `<article>` element."

  attr :card, :map, default: nil, doc: "Optional `%ScalarPayload{}` envelope."

  attr :label, :string, default: nil
  attr :value, :any, default: nil
  attr :unit, :string, default: nil
  attr :trend, :float, default: nil
  attr :meta, :map, default: %{}
  attr :range, :string, default: nil
  attr :hint, :string, default: nil

  attr :primary_link, :map,
    default: nil,
    doc:
      "Optional `%{destination:, id:, external:}`. Auto-filled from `card.runtime.href` when omitted."

  attr :secondary_link, :map,
    default: nil,
    doc:
      "Optional `%{destination:, label:, id:, tone:, size:, icon:, icon_position:, external:}`."

  def metric_card(assigns) do
    assigns = assign_from_card(assigns)

    assigns =
      assigns
      |> assign(:resolved_primary, resolved_primary_link(assigns))
      |> assign(:resolved_secondary, resolved_secondary_link(assigns))

    ~H"""
    <div :if={@resolved_secondary} class="space-y-2">
      <.linked_metric_card_article
        id={@id}
        primary={@resolved_primary}
        label={@label}
        value={@value}
        unit={@unit}
        trend={@trend}
        display={@display}
        range={@range}
        hint={@hint}
      />
      <.metric_card_secondary_link link={@resolved_secondary} />
    </div>
    <.linked_metric_card_article
      :if={!@resolved_secondary}
      id={@id}
      primary={@resolved_primary}
      label={@label}
      value={@value}
      unit={@unit}
      trend={@trend}
      display={@display}
      range={@range}
      hint={@hint}
    />
    """
  end

  attr :id, :string, required: true
  attr :primary, :map, default: nil
  attr :label, :string, default: nil
  attr :value, :any, default: nil
  attr :unit, :string, default: nil
  attr :trend, :float, default: nil
  attr :display, :map, default: nil
  attr :range, :string, default: nil
  attr :hint, :string, default: nil

  defp linked_metric_card_article(assigns) do
    ~H"""
    <.link
      :if={@primary}
      id={@primary.id}
      class="group block"
      {primary_destination_attrs(@primary)}
    >
      <.metric_card_article
        id={@id}
        label={@label}
        value={@value}
        unit={@unit}
        trend={@trend}
        display={@display}
        range={@range}
        hint={@hint}
      />
    </.link>
    <.metric_card_article
      :if={!@primary}
      id={@id}
      label={@label}
      value={@value}
      unit={@unit}
      trend={@trend}
      display={@display}
      range={@range}
      hint={@hint}
    />
    """
  end

  attr :id, :string, required: true
  attr :label, :string, default: nil
  attr :value, :any, default: nil
  attr :unit, :string, default: nil
  attr :trend, :float, default: nil
  attr :display, :map, default: nil
  attr :range, :string, default: nil
  attr :hint, :string, default: nil

  defp metric_card_article(assigns) do
    ~H"""
    <article id={@id} class="zaq-card-default zaq-border-default zaq-card-hover">
      <p
        class="zaq-text-caption uppercase tracking-[0.18em]"
        style="color: var(--zaq-text-color-body-secondary);"
      >
        {@label}
      </p>
      <div class="mt-3 flex items-end justify-between gap-3">
        <p class="zaq-text-h1" style="color: var(--zaq-text-color-body-default);">
          {TelemetryFormat.format_value(@value)}<span
            :if={@unit}
            class="zaq-text-body-sm ml-1"
            style="color: var(--zaq-text-color-body-secondary);"
          >{@unit}</span>
        </p>
        <p
          :if={is_number(@trend)}
          class={[
            "rounded-full px-2 py-1 font-mono text-[0.68rem] transition-colors",
            if(@trend >= 0,
              do: "bg-cyan-50 text-cyan-700",
              else: "bg-slate-100 text-slate-600"
            )
          ]}
        >
          {TelemetryFormat.format_trend_percent(@trend)}
        </p>
      </div>
      <p
        :if={metadata_line(@display, @range, @hint)}
        class="zaq-text-body-sm mt-3"
        style="color: var(--zaq-text-color-body-tertiary);"
      >
        {metadata_line(@display, @range, @hint)}
      </p>
    </article>
    """
  end

  attr :link, :map, required: true

  defp metric_card_secondary_link(assigns) do
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

  defp resolved_primary_link(%{primary_link: link}) when is_map(link) do
    normalize_primary_link(link)
  end

  defp resolved_primary_link(%{
         primary_link: nil,
         card: %ScalarPayload{runtime: %{href: href}} = card
       })
       when is_binary(href) and href != "" do
    %{destination: href, id: card.id, external: false}
  end

  defp resolved_primary_link(%{primary_link: nil}), do: nil

  defp resolved_primary_link(_assigns), do: nil

  defp resolved_secondary_link(%{secondary_link: link}) when is_map(link) do
    normalize_secondary_link(link)
  end

  defp resolved_secondary_link(_assigns), do: nil

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

  defp primary_destination_attrs(%{external: true, destination: destination}),
    do: %{href: destination}

  defp primary_destination_attrs(%{destination: destination}), do: %{navigate: destination}

  defp assign_from_card(%{card: %ScalarPayload{} = card} = assigns) do
    assigns
    |> assign(:label, card.label)
    |> assign(:value, card.value)
    |> assign(:unit, card.unit)
    |> assign(:trend, card.trend)
    |> assign(:display, card.display)
  end

  defp assign_from_card(assigns) do
    display =
      case Map.get(assigns, :meta) do
        %DisplayMeta{} = value -> value
        meta when is_map(meta) -> DisplayMeta.from_map(meta)
        _ -> %DisplayMeta{}
      end

    assign(assigns, :display, display)
  end

  defp metadata_line(display, range, hint) do
    range_value = display_range(display) || range
    hint_value = display_hint(display) || hint

    extra_meta =
      display_extra(display)
      |> Enum.reject(fn {_key, value} -> blank_meta_value?(value) end)
      |> Enum.map(fn {key, value} -> "#{format_meta_key(key)}: #{format_meta_value(value)}" end)

    ([metadata_part("range", range_value), hint_value] ++ extra_meta)
    |> Enum.reject(&blank_meta_value?/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defp metadata_part(_name, value) when value in [nil, ""], do: nil
  defp metadata_part(name, value), do: "#{name}: #{value}"

  defp display_range(%DisplayMeta{range: value}), do: value
  defp display_range(_), do: nil

  defp display_hint(%DisplayMeta{hint: value}), do: value
  defp display_hint(_), do: nil

  defp display_extra(%DisplayMeta{extra: value}) when is_map(value), do: value
  defp display_extra(_), do: %{}

  defp format_meta_key(key) do
    key
    |> key_string()
    |> String.replace("_", " ")
  end

  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key) when is_binary(key), do: key
  defp key_string(key), do: to_string(key)

  defp format_meta_value(value) when is_binary(value), do: value
  defp format_meta_value(value) when is_number(value), do: TelemetryFormat.format_value(value)
  defp format_meta_value(value), do: to_string(value)

  defp blank_meta_value?(value) when value in [nil, ""], do: true
  defp blank_meta_value?(_value), do: false

  defp map_get(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end

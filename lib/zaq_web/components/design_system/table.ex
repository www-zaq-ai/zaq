defmodule ZaqWeb.Components.DesignSystem.Table do
  @moduledoc """
  BO data table — list shell, rows, cells, and shared cell helpers.

  CSS: `assets/css/table.css` (`.zaq-table`, row variants, sidecar, grid cards).

  Grid layout: `ZaqWeb.Components.DesignSystem.Table.Grid` (`grid/1`, `grid_card/1`).

  Row primary action: pass `navigate`, `patch`, or `click` on `table_row/1` (or `grid_card/1`).
  Row surface hover and `cursor-pointer` apply only when a destination is set.
  Checkboxes and `table_actions/1` stop propagation so nested controls do not trigger the row.
  """

  use Phoenix.Component

  import ZaqWeb.Helpers.DateFormat, only: [format_datetime: 1]

  alias Phoenix.LiveView.JS
  alias ZaqWeb.Components.DesignSystem.StatusPill

  defp isolate_click_attrs, do: %{"onclick" => "event.stopPropagation()"}

  @doc "List table shell — `.zaq-table` with optional scroll wrapper and caption."
  attr :id, :string, required: true
  attr :scrollable, :boolean, default: false
  attr :sticky_header, :boolean, default: false
  attr :min_width, :string, default: nil
  attr :class, :any, default: nil

  slot :caption
  slot :head
  slot :body, required: true

  def table(assigns) do
    ~H"""
    <div class={scroll_wrapper_class(@scrollable)}>
      <p :for={cap <- @caption} class="zaq-table-caption zaq-text-caption mb-3">
        {render_slot(cap)}
      </p>
      <table
        id={@id}
        class={[
          "zaq-table zaq-border-default w-full",
          @class
        ]}
        style={table_min_width_style(@min_width)}
      >
        <thead :if={@head != []}>
          {render_slot(@head)}
        </thead>
        <tbody>
          {render_slot(@body)}
        </tbody>
      </table>
    </div>
    """
  end

  @doc "Header row — use inside `<thead>`. Pass `sticky_header` when thead should stick on scroll."
  attr :sticky_header, :boolean, default: false
  slot :inner_block, required: true

  def table_head_row(assigns) do
    ~H"""
    <tr class={@sticky_header && "sticky top-0 z-10"}>
      {render_slot(@inner_block)}
    </tr>
    """
  end

  @doc "Data or header cell — `element` is `:td` or `:th`."
  attr :element, :atom, default: :td, values: [:td, :th]
  attr :align, :atom, default: :left, values: [:left, :right, :center]
  attr :colspan, :integer, default: nil
  attr :width, :string, default: nil
  attr :nowrap, :boolean, default: false
  attr :class, :any, default: nil
  slot :inner_block

  def table_cell(assigns) do
    ~H"""
    <%= case @element do %>
      <% :th -> %>
        <th
          colspan={@colspan}
          class={cell_class(@element, @align, @nowrap, @width, @class)}
        >
          {render_slot(@inner_block)}
        </th>
      <% _ -> %>
        <td
          colspan={@colspan}
          class={cell_class(@element, @align, @nowrap, @width, @class)}
        >
          {render_slot(@inner_block)}
        </td>
    <% end %>
    """
  end

  @doc """
  Table row. Set `navigate`, `patch`, or `click` for whole-row primary action.
  """
  attr :variant, :atom, default: :default, values: [:default, :plain, :sidecar, :selected]
  attr :id, :string, default: nil
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :click, :any, default: nil
  attr :click_values, :map, default: %{}
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def table_row(assigns) do
    assigns =
      assigns
      |> assign(:row_click?, row_click?(assigns))
      |> assign(:row_click_attrs, row_click_attrs(assigns))

    ~H"""
    <tr
      id={@id}
      class={row_class(@variant, @row_click?, @class)}
      {@row_click_attrs}
    >
      {render_slot(@inner_block)}
    </tr>
    """
  end

  @doc "Empty state row — plain variant, centered colspan message."
  attr :colspan, :integer, required: true
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def table_empty(assigns) do
    ~H"""
    <.table_row variant={:plain}>
      <.table_cell colspan={@colspan} align={:center} class={["px-4 py-8 zaq-text-body-sm", @class]}>
        {render_slot(@inner_block)}
      </.table_cell>
    </.table_row>
    """
  end

  @doc "Sidecar sub-row spanning body columns (ingestion converted markdown preview)."
  attr :leading_colspan, :integer, default: 1
  attr :body_colspan, :integer, required: true
  slot :inner_block, required: true

  def table_sidecar_row(assigns) do
    ~H"""
    <.table_row variant={:sidecar}>
      <%= for _ <- 1..@leading_colspan do %>
        <.table_cell />
      <% end %>
      <.table_cell colspan={@body_colspan} class="px-4 py-1.5 overflow-hidden max-w-0">
        {render_slot(@inner_block)}
      </.table_cell>
    </.table_row>
    """
  end

  @doc "Checkbox for header or row — stops row click propagation."
  attr :checked, :boolean, default: false
  attr :class, :any, default: nil

  attr :rest, :global,
    include: ~w(phx-click phx-value-id phx-value-path name id aria-label data-testid)

  def table_checkbox(assigns) do
    ~H"""
    <span {isolate_click_attrs()}>
      <input
        type="checkbox"
        class={["zaq-bo-checkbox zaq-focus-visible", @class]}
        checked={@checked}
        {@rest}
      />
    </span>
    """
  end

  @doc "Text cell content with tone and truncation options."
  attr :label, :string, required: true
  attr :tone, :atom, default: :default, values: [:default, :secondary, :tertiary, :mono]
  attr :truncate, :boolean, default: false
  attr :class, :any, default: nil

  def table_text(assigns) do
    ~H"""
    <span
      class={text_class(@tone, @truncate, @class)}
      style={tone_style(@tone)}
    >
      {@label}
    </span>
    """
  end

  @doc "Status pill — delegates to `StatusPill.status_pill_classes/1`."
  attr :status, :string, required: true
  attr :pulse, :boolean, default: false
  attr :class, :any, default: nil
  slot :inner_block

  def table_badge(assigns) do
    ~H"""
    <span class={StatusPill.status_pill_classes(@status) ++ pulse_class(@pulse) ++ List.wrap(@class)}>
      <%= if @inner_block != [] do %>
        {render_slot(@inner_block)}
      <% else %>
        {@status}
      <% end %>
    </span>
    """
  end

  @doc "Formatted datetime — tertiary body-sm; nil shows placeholder."
  attr :value, :any, default: nil
  attr :align, :atom, default: :left, values: [:left, :right, :center]
  attr :placeholder, :string, default: "—"
  attr :class, :any, default: nil

  def table_datetime(assigns) do
    text = if is_nil(assigns.value), do: assigns.placeholder, else: format_datetime(assigns.value)

    assigns = assign(assigns, :text, text)

    ~H"""
    <span
      class={[
        "zaq-text-body-sm whitespace-nowrap",
        align_class(@align),
        @class
      ]}
      style="color: var(--zaq-text-color-body-tertiary)"
    >
      {@text}
    </span>
    """
  end

  @doc """
  Action cluster — slot for 1..N `Button` / `Link` children.
  `reveal: :hover` hides until the parent table row or grid card is hovered.
  """
  attr :align, :atom, default: :right, values: [:left, :right, :center]
  attr :reveal, :atom, default: :always, values: [:always, :hover]
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def table_actions(assigns) do
    ~H"""
    <div
      {isolate_click_attrs()}
      class={[
        "zaq-table-cell--actions flex items-center gap-1 shrink-0",
        align_class(@align),
        reveal_class(@reveal),
        @class
      ]}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "Icon + label row — icon via `:icon` slot, label via inner block."
  attr :class, :any, default: nil
  slot :icon
  slot :inner_block, required: true

  def table_media(assigns) do
    ~H"""
    <div class={["flex items-center gap-2 min-w-0", @class]}>
      <span :if={@icon != []} class="shrink-0">{render_slot(@icon)}</span>
      <span class="truncate min-w-0">{render_slot(@inner_block)}</span>
    </div>
    """
  end

  @doc "Scroll wrapper class when `scrollable` is true — shared with `Table.Grid`."
  def scroll_wrapper_class(true), do: "zaq-table-scroll"
  def scroll_wrapper_class(_), do: nil

  @doc "Whether row/card assigns include a primary destination — shared with `Table.Grid`."
  def row_click?(assigns) do
    navigate?(assigns) or patch?(assigns) or click?(assigns)
  end

  defp navigate?(assigns), do: is_binary(assigns.navigate) and assigns.navigate != ""
  defp patch?(assigns), do: is_binary(assigns.patch) and assigns.patch != ""
  defp click?(assigns), do: not is_nil(assigns.click) and assigns.click != false

  defp row_click_attrs(assigns) do
    base =
      cond do
        navigate?(assigns) -> %{"phx-click" => JS.navigate(assigns.navigate)}
        patch?(assigns) -> %{"phx-click" => JS.patch(assigns.patch)}
        click?(assigns) -> %{"phx-click" => assigns.click}
        true -> %{}
      end

    Enum.reduce(assigns.click_values, base, fn {key, value}, acc ->
      Map.put(acc, "phx-value-#{key}", value)
    end)
  end

  defp row_class(variant, row_click?, extra) do
    [
      variant_class(variant),
      row_click? && "zaq-table-row--clickable",
      row_click? && "cursor-pointer",
      variant != :plain && variant != :sidecar && "group",
      extra
    ]
  end

  defp variant_class(:plain), do: "zaq-table-row--plain"
  defp variant_class(:sidecar), do: "zaq-table-row--sidecar"
  defp variant_class(:selected), do: "zaq-table-row--selected"
  defp variant_class(_), do: nil

  defp cell_class(:th, align, nowrap, width, extra) do
    [
      "zaq-text-caption px-2 py-2 xl:px-4 xl:py-3.5",
      align_class(align),
      nowrap && "whitespace-nowrap",
      width_class(width),
      extra
    ]
  end

  defp cell_class(:td, align, nowrap, width, extra) do
    [
      "px-2 py-2 xl:px-4 xl:py-3",
      align_class(align),
      nowrap && "whitespace-nowrap",
      width_class(width),
      extra
    ]
  end

  defp align_class(:left), do: "text-left"
  defp align_class(:right), do: "text-right"
  defp align_class(:center), do: "text-center"

  defp width_class(nil), do: nil
  defp width_class(width) when is_binary(width), do: width

  defp text_class(tone, truncate, extra) do
    [
      tone_size_class(tone),
      truncate && "truncate",
      extra
    ]
  end

  defp tone_size_class(:mono), do: "font-mono zaq-text-body-sm"
  defp tone_size_class(:secondary), do: "zaq-text-body-sm"
  defp tone_size_class(:tertiary), do: "zaq-text-body-sm"
  defp tone_size_class(_), do: "zaq-text-body"

  defp tone_style(:secondary), do: "color: var(--zaq-text-color-body-secondary)"
  defp tone_style(:tertiary), do: "color: var(--zaq-text-color-body-tertiary)"
  defp tone_style(_), do: nil

  defp reveal_class(:hover), do: "zaq-table-actions--reveal-hover"
  defp reveal_class(_), do: nil

  defp pulse_class(true), do: ["zaq-pill--pulse"]
  defp pulse_class(_), do: []

  defp table_min_width_style(nil), do: nil
  defp table_min_width_style(width), do: "min-width: #{width}"
end

defmodule ZaqWeb.Components.DesignSystem.Table.Grid do
  @moduledoc """
  Card grid companion to `DesignSystem.Table` — header toolbar + `.zaq-ingestion-file-grid` cards.

  Shares cell helpers and `assets/css/table.css` with the list table.
  """

  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.Table,
    only: [
      scroll_wrapper_class: 1,
      row_click?: 1
    ]

  alias Phoenix.LiveView.JS

  @doc "Grid shell — sticky header table + card grid body."
  attr :id, :string, required: true
  attr :scrollable, :boolean, default: true
  attr :columns, :integer, default: 4
  attr :class, :any, default: nil
  slot :header
  slot :cards, required: true
  slot :empty

  def grid(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "zaq-file-preview-shell flex flex-col min-h-0",
        scroll_wrapper_class(@scrollable),
        @class
      ]}
    >
      <table class="zaq-table zaq-table--ingestion-grid-header w-full shrink-0">
        <thead :if={@header != []}>
          {render_slot(@header)}
        </thead>
      </table>
      <div class="zaq-ingestion-file-grid-cards-wrap min-h-0">
        <%= if @empty != [] do %>
          <div class="py-12 text-center">
            {render_slot(@empty)}
          </div>
        <% else %>
          <div
            class="zaq-ingestion-file-grid"
            style={"grid-template-columns: repeat(#{@columns}, minmax(0, 1fr))"}
          >
            {render_slot(@cards)}
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @doc "Single grid card — optional whole-card primary action via navigate/patch/click."
  attr :selected, :boolean, default: false
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :click, :any, default: nil
  attr :click_values, :map, default: %{}
  attr :class, :any, default: nil
  slot :checkbox
  slot :actions
  slot :inner_block, required: true

  def grid_card(assigns) do
    assigns =
      assigns
      |> assign(:row_click?, row_click?(assigns))
      |> assign(:card_click_attrs, card_click_attrs(assigns))

    ~H"""
    <div
      class={[
        "group zaq-ingestion-file-grid-card",
        @selected && "zaq-ingestion-file-grid-card--selected",
        @row_click? && "cursor-pointer",
        @class
      ]}
      {@card_click_attrs}
    >
      <div
        :if={@checkbox != []}
        class="absolute top-2 left-2 z-10 zaq-ingestion-file-grid-card-checkbox"
      >
        {render_slot(@checkbox)}
      </div>
      <div :if={@actions != []} class="zaq-ingestion-file-grid-card-actions">
        {render_slot(@actions)}
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp card_click_attrs(assigns) do
    cond do
      is_binary(assigns.navigate) and assigns.navigate != "" ->
        %{"phx-click" => JS.navigate(assigns.navigate)}

      is_binary(assigns.patch) and assigns.patch != "" ->
        %{"phx-click" => JS.patch(assigns.patch)}

      not is_nil(assigns.click) and assigns.click != false ->
        Enum.reduce(assigns.click_values, %{"phx-click" => assigns.click}, fn {key, value}, acc ->
          Map.put(acc, "phx-value-#{key}", value)
        end)

      true ->
        %{}
    end
  end
end

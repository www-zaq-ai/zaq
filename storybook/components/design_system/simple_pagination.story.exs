defmodule Storybook.Components.DesignSystem.SimplePagination do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.SimplePagination
  import ZaqWeb.Components.DesignSystem.Table

  def description do
    "Range label with ghost Prev/Next for BO paginated list panels. " <>
      "Renders as-is — no outer chrome. On live pages it typically sits directly below a table."
  end

  def render(assigns) do
    ~H"""
    <div
      class="zaq-text-body flex flex-col gap-10"
      style="padding: var(--zaq-scale-32); max-width: 36rem;"
    >
      <.story_section
        title="Standalone states"
        description="Component only — matches production markup without a decorative wrapper."
      >
        <div class="flex flex-col gap-6">
          <.state_demo label="First page (Next only)">
            <.simple_pagination page={1} per_page={20} total_count={45} />
          </.state_demo>
          <.state_demo label="Middle page (Prev + Next)">
            <.simple_pagination page={2} per_page={20} total_count={45} />
          </.state_demo>
          <.state_demo label="Last page (Prev only)">
            <.simple_pagination page={3} per_page={20} total_count={45} />
          </.state_demo>
          <.state_demo label="Single page (range only)">
            <.simple_pagination page={1} per_page={20} total_count={5} />
          </.state_demo>
        </div>
      </.story_section>

      <.story_section
        title="Below table (/bo/people)"
        description="Typical composition: scrollable table, then pagination as the next sibling."
      >
        <.table id="story-pagination-table">
          <:head>
            <.table_head_row>
              <.table_cell element={:th}>
                <.table_text label="Name" tone={:tertiary} />
              </.table_cell>
            </.table_head_row>
          </:head>
          <:body>
            <.table_row>
              <.table_cell>
                <.table_text label="Ada Lovelace" />
              </.table_cell>
            </.table_row>
          </:body>
        </.table>
        <.simple_pagination page={1} per_page={20} total_count={45} />
      </.story_section>
    </div>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp state_demo(assigns) do
    ~H"""
    <div class="flex flex-col gap-2 min-w-0">
      <span
        class="zaq-text-caption"
        style="color: var(--zaq-text-color-body-tertiary)"
      >
        {@label}
      </span>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :title, :string, required: true
  attr :description, :string, default: nil
  slot :inner_block, required: true

  defp story_section(assigns) do
    ~H"""
    <section class="flex flex-col gap-3 min-w-0">
      <header>
        <h2 class="zaq-text-body font-semibold">{@title}</h2>
        <p
          :if={@description}
          class="zaq-text-body-sm mt-1"
          style="color: var(--zaq-text-color-body-tertiary)"
        >
          {@description}
        </p>
      </header>
      {render_slot(@inner_block)}
    </section>
    """
  end
end

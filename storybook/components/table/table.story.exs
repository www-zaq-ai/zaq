defmodule Storybook.Components.Table.Story do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.Button
  import ZaqWeb.Components.DesignSystem.Link
  import ZaqWeb.Components.DesignSystem.Table
  import ZaqWeb.Components.DesignSystem.Table.Grid

  import ZaqWeb.Components.DesignSystem.IngestionFileIcon,
    only: [file_icon: 1, file_icon_color: 1]

  @demo_dt ~U[2025-03-13 14:05:00Z]

  def description do
    "Reusable BO table system — `DesignSystem.Table` (list) + `Table.Grid` (card grid). " <>
      "Shared helpers: checkbox, text, badge, datetime, actions, media."
  end

  def render(assigns) do
    assigns = assign(assigns, :dt, @demo_dt)

    ~H"""
    <div
      class="zaq-text-body flex flex-col gap-10"
      style="padding: var(--zaq-scale-32); max-width: 100%;"
    >
      <.story_section
        title="Basic list"
        description="Shell, header row, text cells, hover row."
      >
        <.table id="story-table-basic">
          <:head>
            <.table_head_row>
              <.table_cell element={:th}>
                <.table_text label="Name" tone={:tertiary} />
              </.table_cell>
              <.table_cell element={:th} align={:right}>
                <.table_text label="Role" tone={:tertiary} />
              </.table_cell>
            </.table_head_row>
          </:head>
          <:body>
            <.table_row :for={row <- basic_rows()}>
              <.table_cell>
                <.table_text label={row.name} />
              </.table_cell>
              <.table_cell align={:right}>
                <.table_text label={row.role} tone={:tertiary} />
              </.table_cell>
            </.table_row>
          </:body>
        </.table>
      </.story_section>

      <.story_section
        title="Row click + isolated actions"
        description="Whole row uses primary action; checkbox and action links stop propagation."
      >
        <.table id="story-table-row-click">
          <:head>
            <.table_head_row>
              <.table_cell element={:th} width="w-10" />
              <.table_cell element={:th}>
                <.table_text label="Conversation" tone={:tertiary} />
              </.table_cell>
              <.table_cell element={:th} align={:right} />
            </.table_head_row>
          </:head>
          <:body>
            <.table_row
              :for={row <- conversation_rows()}
              id={"conv-#{row.id}"}
              navigate={"/bo/conversations/#{row.id}"}
              variant={if(row.selected, do: :selected, else: :default)}
            >
              <.table_cell width="w-10">
                <.table_checkbox
                  checked={row.selected}
                  phx-click="toggle_select"
                  phx-value-id={row.id}
                />
              </.table_cell>
              <.table_cell>
                <.table_text label={row.title} truncate />
              </.table_cell>
              <.table_cell align={:right}>
                <.table_actions>
                  <.nav_link destination="/bo/conversations/1" external tone={:accent} size={:sm}>
                    View →
                  </.nav_link>
                </.table_actions>
              </.table_cell>
            </.table_row>
          </:body>
        </.table>
      </.story_section>

      <.story_section
        title="Badges, datetime, actions column"
        description="StatusPill badges, right-aligned datetime, always-visible actions."
      >
        <.table id="story-table-rich-cells">
          <:head>
            <.table_head_row>
              <.table_cell element={:th}><.table_text label="User" tone={:tertiary} /></.table_cell>
              <.table_cell element={:th}><.table_text label="Status" tone={:tertiary} /></.table_cell>
              <.table_cell element={:th} align={:right} nowrap>
                <.table_text label="Updated" tone={:tertiary} />
              </.table_cell>
              <.table_cell element={:th} align={:right} />
            </.table_head_row>
          </:head>
          <:body>
            <.table_row :for={row <- user_rows()}>
              <.table_cell>
                <.table_text label={row.name} />
              </.table_cell>
              <.table_cell>
                <.table_badge status={row.status} />
              </.table_cell>
              <.table_cell align={:right} nowrap>
                <.table_datetime value={row.updated_at} align={:right} />
              </.table_cell>
              <.table_cell align={:right}>
                <.table_actions>
                  <.nav_link destination="/bo/users/1/edit" external tone={:accent} size={:sm}>
                    Edit
                  </.nav_link>
                  <.button variant={:tertiary} danger phx-click="delete">
                    Delete
                  </.button>
                </.table_actions>
              </.table_cell>
            </.table_row>
          </:body>
        </.table>
      </.story_section>

      <.story_section
        title="Sidecar sub-row"
        description="Data row plus sidecar preview control spanning columns."
      >
        <.table id="story-table-sidecar" scrollable>
          <:head>
            <.table_head_row sticky_header>
              <.table_cell element={:th}><.table_text label="Name" tone={:tertiary} /></.table_cell>
              <.table_cell element={:th} align={:right} nowrap>
                <.table_text label="Modified" tone={:tertiary} />
              </.table_cell>
            </.table_head_row>
          </:head>
          <:body>
            <.table_row>
              <.table_cell>
                <.table_media>
                  <:icon>
                    <span
                      class="w-4 h-4 rounded zaq-text-accent"
                      style="background: var(--zaq-surface-color-accent)"
                    >
                    </span>
                  </:icon>
                  report.pdf
                </.table_media>
              </.table_cell>
              <.table_cell align={:right} nowrap>
                <.table_datetime value={@dt} align={:right} />
              </.table_cell>
            </.table_row>
            <.table_sidecar_row leading_colspan={1} body_colspan={1}>
              <button type="button" class="zaq-table-sidecar-preview">
                <span class="zaq-table-sidecar-preview-name zaq-text-body">report.md</span>
                <span class="zaq-table-sidecar-preview-meta zaq-text-caption">18 KB</span>
              </button>
            </.table_sidecar_row>
          </:body>
        </.table>
      </.story_section>

      <.story_section
        title="Empty state"
        description="Plain row with colspan message."
      >
        <.table id="story-table-empty">
          <:head>
            <.table_head_row>
              <.table_cell element={:th}><.table_text label="Name" tone={:tertiary} /></.table_cell>
            </.table_head_row>
          </:head>
          <:body>
            <.table_empty colspan={1}>
              <span style="color: var(--zaq-text-color-body-tertiary)">No conversations found.</span>
            </.table_empty>
          </:body>
        </.table>
      </.story_section>

      <.story_section
        title="Hover actions in name cell"
        description={
          "`table_actions` with reveal={:hover} accepts multiple Button/Link children (1..N). " <>
            "Hover the row to reveal the icon toolbar — same pattern as the ingestion file list name cell."
        }
      >
        <.table id="story-table-hover-actions">
          <:head>
            <.table_head_row>
              <.table_cell element={:th}><.table_text label="Name" tone={:tertiary} /></.table_cell>
            </.table_head_row>
          </:head>
          <:body>
            <.table_row>
              <.table_cell>
                <div class="flex items-center justify-between gap-3 min-w-0">
                  <.table_media>
                    <:icon>
                      <span
                        class="w-4 h-4 rounded shrink-0"
                        style="background: var(--zaq-surface-color-accent)"
                      />
                    </:icon>
                    notes.md
                  </.table_media>
                  <.table_actions reveal={:hover}>
                    <.button variant={:ghost} icon="hero-folder" icon_only aria-label="Move to…" />
                    <.button variant={:ghost} icon="hero-pencil-square" icon_only aria-label="Rename" />
                    <.button
                      variant={:ghost}
                      icon="hero-users"
                      icon_only
                      aria-label="Share with roles"
                    />
                    <.button
                      variant={:tertiary}
                      danger
                      icon="hero-trash"
                      icon_only
                      aria-label="Delete"
                    />
                  </.table_actions>
                </div>
              </.table_cell>
            </.table_row>
          </:body>
        </.table>
      </.story_section>

      <.story_section
        title="Grid view"
        description={
          "`Table.Grid.grid/1` — sticky header toolbar + card tiles. " <>
            "Column count is set with the `columns` attribute (integer, default 4); " <>
            "it drives `grid-template-columns: repeat(n, minmax(0, 1fr))`. " <>
            "The number of cards is not fixed — pass any count in the `:cards` slot. " <>
            "Card body is free-form: use `IngestionFileIcon.file_icon/1` for file-type visuals " <>
            "(same as ingestion grid), `table_badge/1` for status, and `table_actions` + `Button` for hover actions."
        }
      >
        <div class="flex flex-col gap-8 min-w-0">
          <.story_subsection
            title="Two columns — columns={2}"
            description="Explicit column count for wider cards (e.g. narrow panels or Storybook demos)."
          >
            <.grid id="story-table-grid-2col" columns={2}>
              <:header>
                <.table_head_row sticky_header>
                  <.table_cell element={:th} width="w-6">
                    <.table_checkbox checked={false} phx-click="select_all" />
                  </.table_cell>
                  <.table_cell element={:th}>
                    <.table_text label="Select all" tone={:tertiary} />
                  </.table_cell>
                </.table_head_row>
              </:header>
              <:cards>
                <.grid_card_demo :for={card <- grid_cards()} card={card} />
              </:cards>
            </.grid>
          </.story_subsection>

          <.story_subsection
            title="Four columns — default"
            description="Omit `columns` or pass columns={4}. Matches ingestion file grid density."
          >
            <.grid id="story-table-grid-4col">
              <:header>
                <.table_head_row sticky_header>
                  <.table_cell element={:th} width="w-6">
                    <.table_checkbox checked={false} phx-click="select_all" />
                  </.table_cell>
                  <.table_cell element={:th}>
                    <.table_text label="Select all" tone={:tertiary} />
                  </.table_cell>
                </.table_head_row>
              </:header>
              <:cards>
                <.grid_card_demo :for={card <- grid_cards_four()} card={card} />
              </:cards>
            </.grid>
          </.story_subsection>
        </div>
      </.story_section>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :description, :string, default: nil
  slot :inner_block, required: true

  defp story_subsection(assigns) do
    ~H"""
    <div class="flex flex-col gap-3 min-w-0">
      <header>
        <h3 class="zaq-text-body-sm font-semibold">{@title}</h3>
        <p
          :if={@description}
          class="zaq-text-body-sm mt-0.5"
          style="color: var(--zaq-text-color-body-tertiary)"
        >
          {@description}
        </p>
      </header>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :card, :map, required: true

  defp grid_card_demo(assigns) do
    ~H"""
    <.grid_card selected={@card.selected} click="open_preview">
      <:checkbox>
        <.table_checkbox
          checked={@card.selected}
          phx-click="toggle_select"
          phx-value-path={@card.path}
        />
      </:checkbox>
      <:actions>
        <.table_actions reveal={:hover} align={:right}>
          <.button variant={:ghost} icon="hero-folder" icon_only aria-label="Move to…" />
          <.button variant={:ghost} icon="hero-pencil-square" icon_only aria-label="Rename" />
          <.button variant={:ghost} icon="hero-users" icon_only aria-label="Share with roles" />
          <.button variant={:tertiary} danger icon="hero-trash" icon_only aria-label="Delete" />
        </.table_actions>
      </:actions>
      <div class="w-full pt-8 pb-3 flex flex-col items-center min-w-0">
        <.file_icon
          name={@card.name}
          class={"w-10 h-10 mb-2 shrink-0 #{file_icon_color(@card.name)}"}
        />
        <span
          class="zaq-text-body-sm text-center leading-tight px-2 truncate max-w-full"
          title={@card.name}
        >
          {@card.name}
        </span>
        <span
          class="zaq-text-caption mt-0.5 text-center"
          style="color: var(--zaq-text-color-body-tertiary)"
        >
          {@card.size}
        </span>
        <.table_badge status={@card.status} class="mt-1" />
      </div>
    </.grid_card>
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

  defp basic_rows do
    [
      %{name: "Emily Carter", role: "Admin"},
      %{name: "James Wright", role: "User"},
      %{name: "Oliver Hughes", role: "Viewer"}
    ]
  end

  defp conversation_rows do
    [
      %{id: 1, title: "Q1 planning notes", selected: true},
      %{id: 2, title: "Support escalation thread", selected: false}
    ]
  end

  defp user_rows do
    [
      %{name: "emily.carter", status: "ingested", updated_at: @demo_dt},
      %{name: "james.wright", status: "failed", updated_at: @demo_dt}
    ]
  end

  defp grid_cards do
    [
      %{
        name: "report.pdf",
        status: "ingested",
        selected: true,
        path: "report.pdf",
        size: "890 KB"
      },
      %{name: "draft.docx", status: "pending", selected: false, path: "draft.docx", size: "44 KB"}
    ]
  end

  defp grid_cards_four do
    [
      %{
        name: "report.pdf",
        status: "ingested",
        selected: false,
        path: "report.pdf",
        size: "890 KB"
      },
      %{name: "notes.md", status: "ingested", selected: false, path: "notes.md", size: "12 KB"},
      %{name: "draft.docx", status: "pending", selected: true, path: "draft.docx", size: "44 KB"},
      %{name: "bad.csv", status: "failed", selected: false, path: "bad.csv", size: "200 B"}
    ]
  end
end

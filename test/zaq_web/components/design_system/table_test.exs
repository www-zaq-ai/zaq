defmodule ZaqWeb.Components.DesignSystem.TableTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import ZaqWeb.Helpers.DateFormat, only: [format_datetime: 1]

  alias ZaqWeb.Components.DesignSystem.Table
  alias ZaqWeb.Components.DesignSystem.Table.Grid

  @dt ~U[2025-03-13 14:05:00Z]

  test "table/1 renders zaq-table shell and body rows" do
    html =
      render_component(fn assigns ->
        ~H"""
        <Table.table id="users-table">
          <:body>
            <Table.table_row>
              <Table.table_cell>
                <Table.table_text label="Jana" />
              </Table.table_cell>
            </Table.table_row>
          </:body>
        </Table.table>
        """
      end)

    assert String.contains?(html, ~s(id="users-table"))
    assert String.contains?(html, "zaq-table")
    assert String.contains?(html, "Jana")
  end

  test "table_row/1 with click and values binds phx-click for row selection" do
    html =
      render_component(&Table.table_row/1,
        click: "select_agent",
        click_values: %{id: 42},
        id: "agent-row-42",
        inner_block: [
          %{
            inner_block: fn _, _ ->
              Table.table_cell(%{
                inner_block: [%{inner_block: fn _, _ -> "Row" end}]
              })
            end
          }
        ]
      )

    assert String.contains?(html, "phx-click")
    assert String.contains?(html, "select_agent")
    assert String.contains?(html, ~s(phx-value-id="42"))
    assert String.contains?(html, ~s(id="agent-row-42"))
  end

  test "table_row/1 with navigate adds cursor-pointer and phx-click" do
    html =
      render_component(&Table.table_row/1,
        navigate: "/bo/conversations/1",
        inner_block: [
          %{
            inner_block: fn _, _ ->
              Table.table_cell(%{
                inner_block: [%{inner_block: fn _, _ -> "Row" end}]
              })
            end
          }
        ]
      )

    assert String.contains?(html, "cursor-pointer")
    assert String.contains?(html, "clickable")
    assert String.contains?(html, "group")
    assert String.contains?(html, "phx-click")
    assert String.contains?(html, "/bo/conversations/1")
  end

  test "table_row/1 without destination omits clickable row class" do
    html =
      render_component(&Table.table_row/1,
        inner_block: [
          %{
            inner_block: fn _, _ ->
              Table.table_cell(%{
                inner_block: [%{inner_block: fn _, _ -> "Row" end}]
              })
            end
          }
        ]
      )

    refute String.contains?(html, "clickable")
    refute String.contains?(html, "cursor-pointer")
    assert String.contains?(html, "group")
  end

  test "table_row/1 selected variant uses selected row class" do
    html =
      render_component(&Table.table_row/1,
        variant: :selected,
        inner_block: [
          %{
            inner_block: fn _, _ ->
              Table.table_cell(%{
                inner_block: [%{inner_block: fn _, _ -> "Selected" end}]
              })
            end
          }
        ]
      )

    assert String.contains?(html, "zaq-table-row")
    assert String.contains?(html, "selected")
  end

  test "table_checkbox/1 renders checkbox with phx-click passthrough" do
    html = render_component(&Table.table_checkbox/1, checked: true, "phx-click": "toggle")

    assert String.contains?(html, "zaq-bo-checkbox")
    assert String.contains?(html, ~s(phx-click="toggle"))
    refute String.contains?(html, "stopPropagation")
  end

  test "table_selection_bar/1 hidden when selected_count is zero" do
    html =
      render_component(&Table.table_selection_bar/1,
        selected_count: 0,
        actions: []
      )

    refute String.contains?(html, "selected")
    refute String.contains?(html, "zaq-table-selection-bar")
  end

  test "table_selection_bar/1 shows count for one or more selections" do
    html =
      render_component(&Table.table_selection_bar/1,
        selected_count: 1,
        actions: []
      )

    assert String.contains?(html, "1 selected")
    assert String.contains?(html, "zaq-table-selection-bar")
    assert String.contains?(html, "zaq-text-body-sm")

    multi =
      render_component(&Table.table_selection_bar/1,
        selected_count: 3,
        actions: []
      )

    assert String.contains?(multi, "3 selected")
  end

  test "table_selection_bar/1 renders actions slot" do
    html =
      render_component(&Table.table_selection_bar/1,
        selected_count: 2,
        actions: [%{inner_block: fn _, _ -> "Deselect all" end}]
      )

    assert String.contains?(html, "zaq-table-selection-bar__actions")
    assert String.contains?(html, "Deselect all")
  end

  test "table_actions/1 does not stop propagation on wrapper (phx-click children must reach LiveView)" do
    html =
      render_component(&Table.table_actions/1,
        reveal: :hover,
        inner_block: [%{inner_block: fn _, _ -> "Action" end}]
      )

    refute String.contains?(html, "stopPropagation")
  end

  test "table_actions/1 hover reveal adds CSS reveal class" do
    html =
      render_component(&Table.table_actions/1,
        reveal: :hover,
        inner_block: [%{inner_block: fn _, _ -> "Action" end}]
      )

    assert String.contains?(html, "zaq-table-actions--reveal-hover")
    assert String.contains?(html, "zaq-table-cell")
  end

  test "table_datetime/1 formats value and placeholder" do
    formatted = render_component(&Table.table_datetime/1, value: @dt)
    assert String.contains?(formatted, "2025-03-13")
    assert String.contains?(formatted, "05")

    empty = render_component(&Table.table_datetime/1, value: nil)
    assert String.contains?(empty, format_datetime(nil))
  end

  test "table_badge/1 uses StatusPill classes" do
    html = render_component(&Table.table_badge/1, status: "failed")

    assert String.contains?(html, "zaq-pill")
    assert String.contains?(html, "failed")
  end

  test "table_empty/1 renders plain row with colspan" do
    html =
      render_component(&Table.table_empty/1,
        colspan: 3,
        inner_block: [%{inner_block: fn _, _ -> "Empty" end}]
      )

    assert String.contains?(html, "plain")
    assert String.contains?(html, "colspan")
    assert String.contains?(html, "Empty")
  end

  test "grid/1 renders header table and card grid container" do
    html =
      render_component(fn assigns ->
        ~H"""
        <Grid.grid id="file-grid">
          <:cards>
            <Grid.grid_card>
              Card
            </Grid.grid_card>
          </:cards>
        </Grid.grid>
        """
      end)

    assert String.contains?(html, "ingestion-grid-header")
    assert String.contains?(html, "zaq-ingestion-file-grid")
    assert String.contains?(html, "zaq-ingestion-file-grid-card")
    assert String.contains?(html, "Card")
  end

  test "grid_card/1 selected state adds modifier class" do
    html =
      render_component(&Grid.grid_card/1,
        selected: true,
        inner_block: [%{inner_block: fn _, _ -> "Tile" end}]
      )

    assert String.contains?(html, "zaq-ingestion-file-grid-card")
    assert String.contains?(html, "selected")
  end
end

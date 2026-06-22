defmodule ZaqWeb.Components.DesignSystem.SimplePaginationTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.SimplePagination

  test "simple_pagination/1 renders range and next on first page" do
    html =
      render_component(&SimplePagination.simple_pagination/1,
        page: 1,
        per_page: 20,
        total_count: 45
      )

    assert html =~ "1–20 of 45"
    assert html =~ "Next →"
    refute html =~ "← Prev"
  end

  test "simple_pagination/1 renders prev and next on middle page" do
    html =
      render_component(&SimplePagination.simple_pagination/1,
        page: 2,
        per_page: 20,
        total_count: 45
      )

    assert html =~ "21–40 of 45"
    assert html =~ "← Prev"
    assert html =~ "Next →"
    assert html =~ ~s(phx-value-page="1")
    assert html =~ ~s(phx-value-page="3")
  end

  test "simple_pagination/1 hides footer when total_count is zero" do
    html =
      render_component(&SimplePagination.simple_pagination/1,
        page: 1,
        per_page: 20,
        total_count: 0
      )

    refute html =~ "of 0"
  end
end

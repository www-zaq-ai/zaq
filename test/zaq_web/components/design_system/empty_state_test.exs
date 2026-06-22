defmodule ZaqWeb.Components.DesignSystem.EmptyStateTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.EmptyState

  test "empty_state/1 renders title" do
    html = render_component(&EmptyState.empty_state/1, title: "No people yet.")

    assert html =~ "No people yet."
  end

  test "empty_state/1 renders optional hint" do
    html =
      render_component(&EmptyState.empty_state/1,
        title: "No teams yet.",
        hint: "Click \"New Team\" to add one."
      )

    assert html =~ "No teams yet."
    assert html =~ "Click &quot;New Team&quot; to add one."
  end
end

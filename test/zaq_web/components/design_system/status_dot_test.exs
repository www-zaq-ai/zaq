defmodule ZaqWeb.Components.DesignSystem.StatusDotTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.StatusDot

  test "status_dot/1 renders active and inactive dots" do
    active = render_component(&StatusDot.status_dot/1, status: :active)
    inactive = render_component(&StatusDot.status_dot/1, status: :inactive)

    assert active =~ "zaq-status-dot--active"
    refute active =~ "zaq-status-dot-count"

    assert inactive =~ "zaq-status-dot--inactive"
    refute inactive =~ "zaq-status-dot-count"
  end

  test "status_dot/1 renders counter when count is positive" do
    html = render_component(&StatusDot.status_dot/1, status: :active, count: 12)

    assert html =~ "zaq-status-dot-group"
    assert html =~ "zaq-status-dot-count"
    assert html =~ ">12<"
  end

  test "status_dot/1 omits counter for zero or nil count" do
    zero = render_component(&StatusDot.status_dot/1, status: :active, count: 0)
    none = render_component(&StatusDot.status_dot/1, status: :inactive)

    refute zero =~ "zaq-status-dot-count"
    refute none =~ "zaq-status-dot-count"
  end

  test "format_count/1 caps at +99" do
    assert StatusDot.format_count(99) == "99"
    assert StatusDot.format_count(100) == "+99"
    assert StatusDot.format_count(500) == "+99"
  end
end

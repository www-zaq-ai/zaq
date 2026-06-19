defmodule ZaqWeb.Components.DesignSystem.StatusBadgeTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.StatusBadge

  test "status_badge/1 renders expected states" do
    assert render_component(&StatusBadge.status_badge/1, status: :idle) =~ "idle"
    assert render_component(&StatusBadge.status_badge/1, status: :loading) =~ "testing"
    assert render_component(&StatusBadge.status_badge/1, status: :ok) =~ "connected"
    assert render_component(&StatusBadge.status_badge/1, status: {:error, :boom}) =~ "error"
  end
end

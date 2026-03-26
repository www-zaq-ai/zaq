defmodule ZaqWeb.Components.BOLayoutTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.BOLayout

  test "bo_layout/1 renders sidebar, header, and content" do
    html =
      render_component(&BOLayout.bo_layout/1,
        current_user: %{username: "alice", role: %{name: "admin"}},
        page_title: "Ops",
        current_path: "/bo/dashboard",
        inner_block: [%{inner_block: fn _, _ -> "Inner Content" end}]
      )

    assert html =~ "id=\"bo-sidebar\""
    assert html =~ "id=\"bo-main\""
    assert html =~ "Ops"
    assert html =~ "Inner Content"
    assert html =~ "/bo/dashboard"
    assert html =~ "alice"
    assert html =~ "admin"
  end

  test "status_badge/1 renders expected states" do
    assert render_component(&BOLayout.status_badge/1, status: :idle) =~ "idle"
    assert render_component(&BOLayout.status_badge/1, status: :loading) =~ "testing"
    assert render_component(&BOLayout.status_badge/1, status: :ok) =~ "connected"
    assert render_component(&BOLayout.status_badge/1, status: {:error, :boom}) =~ "error"
  end

  test "config_row/1 renders hint and truncate class" do
    html =
      render_component(&BOLayout.config_row/1,
        label: "Endpoint",
        value: "https://example.test",
        truncate: true,
        hint: "API URL"
      )

    assert html =~ "Endpoint"
    assert html =~ "https://example.test"
    assert html =~ "API URL"
    assert html =~ "truncate"
  end

  test "bo_layout/1 renders sidebar version with app version fallback" do
    expected_version =
      :zaq
      |> Application.spec(:vsn)
      |> case do
        nil -> "dev"
        version -> to_string(version)
      end

    html =
      render_component(&BOLayout.bo_layout/1,
        current_user: %{username: "alice", role: %{name: "admin"}},
        page_title: "Ops",
        current_path: "/bo/dashboard",
        inner_block: [%{inner_block: fn _, _ -> "Inner Content" end}]
      )

    assert html =~ "sidebar-version"
    assert html =~ "v#{expected_version}"
    assert html =~ "#bo-sidebar.collapsed .sidebar-version"
  end

  test "bo_layout/1 keeps logout and version in the same footer row" do
    html =
      render_component(&BOLayout.bo_layout/1,
        current_user: %{username: "alice", role: %{name: "admin"}},
        page_title: "Ops",
        current_path: "/bo/dashboard",
        inner_block: [%{inner_block: fn _, _ -> "Inner Content" end}]
      )

    assert html =~ "mt-2.5 flex items-center gap-2"
    assert html =~ "Logout"
    assert html =~ "sidebar-version ml-auto"
  end
end

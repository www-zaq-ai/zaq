defmodule ZaqWeb.Components.BOLayoutTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.BOLayout

  test "bo_layout/1 renders page subtitle and tag slot in header" do
    html =
      render_component(&BOLayout.bo_layout/1,
        current_user: %{
          username: "alice",
          role: %{name: "admin"},
          portal_consent: nil,
          email: nil
        },
        page_title: "Workflows",
        page_subtitle: "Automated multi-step processes.",
        current_path: "/bo/workflows",
        page_tag: [%{inner_block: fn _, _ -> "active" end}],
        inner_block: [%{inner_block: fn _, _ -> "Inner Content" end}]
      )

    assert html =~ "id=\"bo-page-heading\""
    assert html =~ "id=\"bo-page-title\""
    assert html =~ "id=\"bo-page-subtitle\""
    assert html =~ "id=\"bo-page-tag\""
    assert html =~ "Workflows"
    assert html =~ "Automated multi-step processes."
    assert html =~ "active"
    assert html =~ "data-testid=\"bo-main-page-heading\""
    assert html =~ "zaq-text-body"
    refute html =~ "zaq-text-body-lg"
  end

  test "bo_layout/1 renders page icon from provider id" do
    html =
      render_component(&BOLayout.bo_layout/1,
        current_user: %{
          username: "alice",
          role: %{name: "admin"},
          portal_consent: nil,
          email: nil
        },
        page_title: "Mattermost",
        page_subtitle: "Self-hosted messaging with full control.",
        page_icon_provider: "mattermost",
        page_icon_accent: "#0058CC",
        current_path: "/bo/channels/retrieval/mattermost",
        inner_block: [%{inner_block: fn _, _ -> "Inner Content" end}]
      )

    assert html =~ "id=\"bo-page-icon\""
    assert html =~ "max-w-2xl"
    assert html =~ "w-10 h-10"
    assert html =~ "background-color: #0058CC14"
  end

  test "bo_layout/1 renders sidebar, header, and content" do
    html =
      render_component(&BOLayout.bo_layout/1,
        current_user: %{
          username: "alice",
          role: %{name: "admin"},
          portal_consent: nil,
          email: nil
        },
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
    assert html =~ "id=\"header-user-trigger\""
    assert html =~ "Account menu: alice"
    assert html =~ "zaq-account-avatar"
    assert html =~ "href=\"/bo/profile\""
    assert html =~ "method=\"post\" action=\"/bo/session\""
    assert html =~ "name=\"_method\" value=\"delete\""
    assert html =~ "id=\"header-user-dropdown\""
    assert html =~ "id=\"header-logout-form\""
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
        current_user: %{
          username: "alice",
          role: %{name: "admin"},
          portal_consent: nil,
          email: nil
        },
        page_title: "Ops",
        current_path: "/bo/dashboard",
        inner_block: [%{inner_block: fn _, _ -> "Inner Content" end}]
      )

    assert html =~ "sidebar-version"
    assert html =~ "v#{expected_version}"
    assert html =~ "#bo-sidebar.collapsed .sidebar-version"
    assert html =~ "#bo-sidebar.collapsed .sidebar-logo"
    assert html =~ "#bo-sidebar.collapsed #sidebar-github-link"
  end

  test "bo_layout/1 moves user actions to header dropdown" do
    html =
      render_component(&BOLayout.bo_layout/1,
        current_user: %{
          username: "alice",
          role: %{name: "admin"},
          portal_consent: nil,
          email: nil
        },
        page_title: "Ops",
        current_path: "/bo/dashboard",
        inner_block: [%{inner_block: fn _, _ -> "Inner Content" end}]
      )

    assert html =~ "id=\"header-user-menu\""
    assert html =~ "id=\"header-notifications-link\""
    assert html =~ "id=\"header-settings-menu\""
    assert html =~ "id=\"header-settings-diagnostics-link\""
    assert html =~ "id=\"header-settings-prompt-templates-link\""
    assert html =~ "id=\"header-settings-system-config-link\""
    assert html =~ "id=\"header-settings-channels-link\""
    assert html =~ "id=\"header-settings-users-link\""
    assert html =~ "id=\"header-settings-roles-link\""
    assert html =~ "id=\"header-settings-license-link\""
    assert html =~ "id=\"header-profile-link\""
    assert html =~ "id=\"header-logout-button\""
    assert html =~ "id=\"sidebar-github-link\""
    assert html =~ "Star Zaq on GitHub"
    assert html =~ "People Directory"

    refute html =~ "id=\"sidebar-profile-link\""
    refute html =~ "id=\"header-system-config-link\""
    refute html =~ "id=\"header-system-license-link\""
    assert html =~ "id=\"section-data\""
    assert html =~ "id=\"section-communication\""
    refute html =~ "logout-btn"

    assert html =~ "Logout"
    assert html =~ "sidebar-version"
  end

  test "bo_layout/1 renders update badge when enabled" do
    html =
      render_component(&BOLayout.bo_layout/1,
        current_user: %{
          username: "alice",
          role: %{name: "admin"},
          portal_consent: nil,
          email: nil
        },
        page_title: "Ops",
        current_path: "/bo/dashboard",
        update_badge_enabled: true,
        inner_block: [%{inner_block: fn _, _ -> "Inner Content" end}]
      )

    assert html =~ "id=\"sidebar-version-update-badge\""
    assert html =~ "https://github.com/www-zaq-ai/zaq/releases"
    assert html =~ "target=\"_blank\""
    assert html =~ "rel=\"noopener noreferrer\""
    assert html =~ "version-update-badge"
  end

  test "bo_layout/1 renders inline flash inside content area" do
    html =
      render_component(&BOLayout.bo_layout/1,
        current_user: %{
          username: "alice",
          role: %{name: "admin"},
          portal_consent: nil,
          email: nil
        },
        page_title: "Ingestion",
        current_path: "/bo/ingestion",
        flash: %{"info" => "Ingestion started."},
        inner_block: [%{inner_block: fn _, _ -> "Inner Content" end}]
      )

    assert html =~ "class=\"p-8\""
    refute html =~ "id=\"bo-flash-stack\""
    refute html =~ "zaq-feedback-stack"
    assert html =~ "id=\"flash-info\""
    assert html =~ "Ingestion started."
  end

  test "bo_layout/1 hides update badge when disabled" do
    html =
      render_component(&BOLayout.bo_layout/1,
        current_user: %{
          username: "alice",
          role: %{name: "admin"},
          portal_consent: nil,
          email: nil
        },
        page_title: "Ops",
        current_path: "/bo/dashboard",
        update_badge_enabled: false,
        inner_block: [%{inner_block: fn _, _ -> "Inner Content" end}]
      )

    refute html =~ "id=\"sidebar-version-update-badge\""
  end
end

defmodule ZaqWeb.Components.DesignSystem.PageHeaderTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.{PageHeader, PersonHeader}

  test "shared heading preserves title, subtitle and tag contracts" do
    html =
      render_component(&PageHeader.page_heading/1,
        id: "sample",
        title: "Profile",
        description: "About you",
        tag: [%{inner_block: fn _, _ -> "Read-only" end}]
      )

    assert html =~ "id=\"sample-title\""
    assert html =~ "About you"
    assert html =~ "Read-only"
    assert html =~ "zaq-text-body"
  end

  test "custom subtitle takes precedence and empty heading uses larger text" do
    html =
      render_component(&PageHeader.page_heading/1,
        title: "Profile",
        description: "Fallback",
        subtitle: [%{inner_block: fn _, _ -> "Custom subtitle" end}]
      )

    assert html =~ "Custom subtitle"
    refute html =~ "Fallback"
    assert render_component(&PageHeader.page_heading/1, title: "Profile") =~ "zaq-text-body-lg"
  end

  test "People header nests mobile-aware theme controls in Settings and keeps People destinations" do
    html =
      render_component(&PersonHeader.person_header/1,
        title: "Profile",
        description: "About you",
        person_permissions: MapSet.new([:access_profile, :access_message_history])
      )

    assert html =~ "/images/zaq.png"
    assert html =~ "alt=\"ZAQ\""
    assert html =~ "Appearance"
    refute html =~ "No personal settings available yet."
    assert html =~ "id=\"people-settings-panel\""
    assert html =~ "zaq-card-default"
    assert html =~ "zaq-card-hover"
    assert html =~ "zaq-border-default"
    assert html =~ "zaq-header-menu-panel"
    assert html =~ "zaq-layout-inline relative"
    refute html =~ "id=\"people-settings-menu\" class=\"relative\""
    assert html =~ "/people/profile"
    assert html =~ "action=\"/people/session\""
    assert html =~ "value=\"delete\""
    assert html =~ "aria-label=\"Use dark theme\""
    assert html =~ "aria-label=\"Use light theme\""
    assert html =~ "aria-label=\"Use system theme\""
    assert html =~ "hidden sm:block"
    assert html =~ "flex-nowrap gap-2 sm:flex-wrap sm:gap-4"
    refute html =~ "/bo/"
    refute html =~ "bo-sidebar"
  end

  test "People header derives the same settings destinations from permissions on every page" do
    allowed_permissions = MapSet.new([:access_profile, :access_message_history])

    for title <- ["Profile", "Credentials", "Conversations", "Conversation"] do
      html =
        render_component(&PersonHeader.person_header/1,
          title: title,
          person_permissions: allowed_permissions
        )

      assert html =~ "id=\"people-conversations-link\""
      assert html =~ "href=\"/people/history\""
      assert html =~ "id=\"people-credentials-link\""
    end

    html =
      render_component(&PersonHeader.person_header/1,
        title: "Credentials",
        person_permissions: MapSet.new([:access_profile])
      )

    refute html =~ "id=\"people-conversations-link\""
    assert html =~ "id=\"people-credentials-link\""
  end

  test "People header denies Conversations for non-MapSet permissions" do
    for permissions <- [
          nil,
          [],
          [:access_profile, :access_message_history],
          %{access_profile: true, access_message_history: true},
          "access_profile access_message_history",
          false
        ] do
      html =
        render_component(&PersonHeader.person_header/1,
          title: "Credentials",
          person_permissions: permissions
        )

      refute html =~ "id=\"people-conversations-link\""
      refute html =~ "href=\"/people/history\""
      assert html =~ "id=\"people-credentials-link\""
      assert html =~ "href=\"/people/credentials\""
      assert html =~ "href=\"/people/profile\""
      assert html =~ "action=\"/people/session\""
    end
  end

  test "People Conversations requires both permissions" do
    for permissions <- [
          MapSet.new(),
          MapSet.new([:access_message_history]),
          MapSet.new(["access_profile", "access_message_history"])
        ] do
      html =
        render_component(&PersonHeader.person_header/1,
          title: "Credentials",
          person_permissions: permissions
        )

      refute html =~ "id=\"people-conversations-link\""
      refute html =~ "href=\"/people/history\""
    end
  end

  property "list permissions never grant People Conversations access" do
    check all(
            permissions <-
              list_of(member_of([:access_profile, :access_message_history, :unrelated]),
                max_length: 8
              )
          ) do
      html =
        render_component(&PersonHeader.person_header/1,
          title: "Credentials",
          person_permissions: permissions
        )

      refute html =~ "id=\"people-conversations-link\""
      refute html =~ "href=\"/people/history\""
      assert html =~ "id=\"people-credentials-link\""
    end
  end
end

defmodule ZaqWeb.Components.DesignSystem.ChannelPriorityListTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.ChannelPriorityList
  alias ZaqWeb.Components.PersonLayout

  test "read mode shows platform icons and identifiers without move controls" do
    html = render_list(false)

    assert html =~ ~s(<table id="test-priority-table")

    assert_in_order(html, [
      "Priority 1",
      "Mattermost",
      "alex.morgan",
      "Priority 2",
      "Email",
      "alex@example.test",
      "Priority 3",
      "Slack",
      "alex · Product workspace"
    ])

    assert html =~ "<svg"
    refute html =~ "Move up"
    refute html =~ "Move down"
    refute html =~ "draggable=\"true\""
  end

  test "edit mode has named move alternatives, boundary disabling and drag handles" do
    html = render_list(true)
    assert html =~ "Move up"
    assert html =~ "Move down"
    assert html =~ "disabled"
    assert html =~ "draggable=\"true\""
    assert html =~ "aria-hidden=\"true\""
  end

  test "shell defaults narrow and only explicitly requested profile content is wide" do
    inner = [%{inner_block: fn _, _ -> "Profile content" end}]
    narrow = render_component(&PersonLayout.person_layout/1, flash: %{}, inner_block: inner)

    wide =
      render_component(&PersonLayout.person_layout/1,
        flash: %{},
        content_width: :wide,
        inner_block: inner
      )

    assert narrow =~ "max-w-lg"
    refute wide =~ "max-w-lg"
    assert wide =~ "max-w-6xl"
    refute narrow =~ "people-header"
    assert narrow =~ ">ZAQ</span>"

    authenticated =
      render_component(&PersonLayout.person_layout/1,
        flash: %{},
        authenticated: true,
        inner_block: inner
      )

    assert authenticated =~ "aria-label=\"People\""
    assert authenticated =~ "max-w-lg"
    assert authenticated =~ "action=\"/people/session\""
  end

  defp render_list(editing) do
    render_component(&ChannelPriorityList.channel_priority_list/1,
      id: "test-priority",
      channels: [
        %{id: "1", provider: "mattermost", platform: "Mattermost", identifier: "alex.morgan"},
        %{id: "2", provider: "email", platform: "Email", identifier: "alex@example.test"},
        %{id: "3", provider: "slack", platform: "Slack", identifier: "alex · Product workspace"}
      ],
      editing: editing
    )
  end

  defp assert_in_order(html, values) do
    offsets =
      Enum.map(values, fn value ->
        assert html =~ value
        {offset, _length} = :binary.match(html, value)
        offset
      end)

    assert offsets == Enum.sort(offsets)
  end
end

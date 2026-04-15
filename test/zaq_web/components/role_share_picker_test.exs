defmodule ZaqWeb.Components.RoleSharePickerTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.RoleSharePicker

  test "renders private state and empty roles message" do
    html =
      render_component(&RoleSharePicker.role_share_picker/1,
        roles: [],
        selected_role_ids: []
      )

    assert html =~ "Private — only your role can access ingested content"
    assert html =~ "\n      private\n"
    assert html =~ "No roles defined yet."
  end

  test "renders shared state with selected count" do
    roles = [%{id: 1, name: "Admin"}, %{id: 2, name: "Editor"}]

    html =
      render_component(&RoleSharePicker.role_share_picker/1,
        roles: roles,
        selected_role_ids: [1, 2]
      )

    assert html =~ "Shared with 2 role(s)"
    assert html =~ "\n      shared\n"
    assert html =~ "Admin"
    assert html =~ "Editor"
  end

  test "renders checkboxes with selected state and custom toggle event" do
    roles = [%{id: 10, name: "Ops"}, %{id: 11, name: "Finance"}]

    html =
      render_component(&RoleSharePicker.role_share_picker/1,
        roles: roles,
        selected_role_ids: [10],
        toggle_event: "toggle_role_access"
      )

    assert html =~ "phx-click=\"toggle_role_access\""
    assert html =~ "phx-value-role_id=\"10\""
    assert html =~ "phx-value-role_id=\"11\""
    assert html =~ "checked"
  end
end

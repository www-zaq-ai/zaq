defmodule ZaqWeb.SearchableSelectTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.SearchableSelect

  test "clear action is opt-in, accessible and hidden for an empty value" do
    base = [id: "clearable", name: "value", options: [{"No value", ""}, {"Paris", "Paris"}]]

    refute render_component(&SearchableSelect.searchable_select/1, base) =~ "data-select-clear"

    for {value, disabled} <- [{"Paris", false}, {"", false}, {"Paris", true}] do
      html =
        render_component(
          &SearchableSelect.searchable_select/1,
          base ++ [clearable: true, value: value, disabled: disabled]
        )

      button = html |> LazyHTML.from_fragment() |> LazyHTML.query("button[data-select-clear]")
      assert LazyHTML.attribute(button, "aria-label") == ["Clear value"]
      assert LazyHTML.attribute(button, "hidden") != [] == (value == "")
      assert LazyHTML.attribute(button, "disabled") != [] == disabled
    end
  end

  test "supports component event routing and an optional disabled value creation picker" do
    html =
      render_component(&SearchableSelect.searchable_select/1,
        id: "value-picker",
        name: "value",
        options: [],
        target: 12,
        event_context: %{label_id: "34"},
        on_search: "search_values",
        on_create_event: "create_value",
        allow_create: true,
        create_on_no_exact_match: true,
        disabled: true,
        maxlength: 200
      )

    assert html =~ ~s(data-event-target="12")
    assert html =~ "label_id"
    assert html =~ ~s(data-server-search="search_values")
    assert html =~ ~s(data-create-event="create_value")
    assert html =~ ~s(data-create-on-no-exact-match="true")
    assert html =~ ~s(maxlength="200")
    assert html =~ "disabled"
  end

  test "renders inline label and wraps control by default" do
    html =
      render_component(&SearchableSelect.searchable_select/1,
        id: "team-select",
        name: "team_id",
        label: "Team",
        options: [{"Engineering", 1}],
        value: 1
      )

    assert html =~ "zaq-field-row-inline"
    assert html =~ ~s(for="team-select-trigger")
    assert html =~ "zaq-field-label-uppercase zaq-text-caption"
    assert html =~ "Team"
    assert html =~ "zaq-field-row-inline-control"
    assert html =~ ~s(id="team-select")
    assert html =~ ~s(name="team_id")
    assert html =~ "zaq-text-body-sm zaq-dropdown-menu-item"
    assert html =~ "Engineering"
  end

  test "compact mode applies body-sm typography to trigger label" do
    html =
      render_component(&SearchableSelect.searchable_select/1,
        id: "role-select",
        name: "role",
        compact: true,
        searchable: false,
        options: [{"Admin", "admin"}],
        value: "admin"
      )

    assert html =~ "zaq-control-combobox-trigger--compact"
    assert html =~ ~s(data-select-label class="zaq-text-body-sm truncate min-w-0")
    assert html =~ "zaq-text-body-sm zaq-dropdown-menu-item"
  end

  test "does not render label wrapper for non-binary label" do
    html =
      render_component(&SearchableSelect.searchable_select/1,
        id: "team-select",
        name: "team_id",
        label: :team,
        options: [{"Engineering", 1}],
        value: 1
      )

    refute html =~ "zaq-field-row-inline"
    refute html =~ "zaq-field-row-block"
    refute html =~ "zaq-field-label-uppercase"
    assert html =~ ~s(id="team-select")
    assert html =~ ~s(name="team_id")
    assert html =~ "Engineering"
  end
end

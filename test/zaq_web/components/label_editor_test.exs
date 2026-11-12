defmodule ZaqWeb.Components.LabelEditorTest do
  use ZaqWeb.ConnCase, async: true
  use ExUnitProperties
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  alias Zaq.Ingestion.{Document, Labels}
  alias Zaq.Ingestion.Labels.DocumentAssignment
  alias ZaqWeb.Components.DesignSystem.LabelChips
  alias ZaqWeb.Components.DesignSystem.LabelEditor, as: Editor
  alias ZaqWeb.Components.DesignSystem.LabelValue

  describe "typed presentation" do
    property "rendered scalar controls round-trip native values without losing false or zero" do
      check all(
              value <-
                one_of([
                  boolean(),
                  integer(),
                  string(:alphanumeric, min_length: 1, max_length: 80)
                ]),
              max_runs: 30
            ) do
        definition =
          cond do
            is_boolean(value) ->
              %{value_type: "boolean", value_config: %{}}

            is_integer(value) ->
              %{
                value_type: "scale",
                value_config: %{"min" => value, "max" => value + 1, "increment" => 1}
              }

            true ->
              %{
                value_type: "options",
                value_config: %{"options" => [%{"id" => value, "label" => "Display"}]}
              }
          end

        html =
          render_component(&LabelValue.value_input/1,
            definition: definition,
            id: "round-trip",
            value: value
          )

        [wire_value] = query_html(html, ~s(input[name="value"])) |> LazyHTML.attribute("value")
        assert LabelValue.parse_input(definition, wire_value) == {:ok, value}
      end
    end

    test "Boolean false and scale zero render as values with definition-owned controls" do
      boolean = %{id: 91, name: "Approved", value_type: "boolean", value_config: %{}}

      html =
        render_component(&LabelValue.value_input/1,
          definition: boolean,
          id: "typed-boolean",
          value: false
        )

      assert html =~ ~s(value="false")
      assert html =~ ~s(data-select-label)

      assert query_html(html, "[data-select-label]") |> LazyHTML.text() |> String.trim() ==
               "False"

      assert Enum.empty?(query_html(html, "[data-select-create]"))

      scale = %{
        id: 92,
        name: "Score",
        value_type: "scale",
        value_config: %{"min" => -2, "max" => 10, "increment" => 0.5}
      }

      html =
        render_component(&LabelValue.value_input/1,
          definition: scale,
          id: "typed-scale",
          value: 0,
          editable: false
        )

      assert Enum.count(
               query_html(
                 html,
                 ~s(input[type="number"][value="0"][min="-2"][max="10"][step="0.5"][disabled])
               )
             ) == 1

      assert LabelValue.display_label(Map.put(boolean, :value, false)) == "Approved: False"
      assert LabelValue.display_label(Map.put(scale, :value, 0)) == "Score: 0"
    end

    test "defined options retain stable IDs and format display labels without creation" do
      definition = %{
        id: 93,
        name: "Office",
        value_type: "options",
        value_config: %{"options" => [%{"id" => "office-1", "label" => "Paris <HQ>"}]}
      }

      html =
        render_component(&LabelValue.value_input/1,
          definition: definition,
          id: "typed-options",
          value: "office-1"
        )

      assert Enum.count(query_html(html, ~s([data-select-value="office-1"]))) == 1
      assert html =~ "Paris &lt;HQ&gt;"
      assert Enum.empty?(query_html(html, "[data-select-create]"))
      assert LabelValue.format_value(definition, "office-1") == "Paris <HQ>"
      assert LabelValue.parse_input(definition, "office-1") == {:ok, "office-1"}
      # Serialization does not duplicate the domain's option-membership validation.
      assert LabelValue.parse_input(definition, "unknown") == {:ok, "unknown"}
    end

    test "typed editor and chips distinguish pending from assigned and excluded" do
      pending = %{
        id: 94,
        name: "Review",
        description: "Awaiting evaluation",
        value_type: "boolean",
        value_config: %{},
        value: nil,
        state: :pending
      }

      excluded = %{pending | id: 95, name: "Excluded label", state: :excluded}

      html =
        render_component(&Editor.label_editor/1,
          labels: [pending, excluded],
          selected: MapSet.new([94]),
          editable: true,
          query: "Excluded"
        )

      assert query_html(html, "#active-resource-labels") |> LazyHTML.text() =~ "Pending automatic"
      assert query_html(html, "#available-resource-labels") |> LazyHTML.text() =~ "Excluded"
      assert Enum.empty?(query_html(html, "[data-select-create]"))

      html =
        render_component(&LabelChips.label_chips/1,
          labels: [pending, excluded],
          resource_id: 1
        )

      assert html =~ "Review: Pending automatic"
      refute html =~ "Excluded label"
      assert LabelValue.display_label(excluded) == "Excluded label: Excluded"
    end

    test "HTML parsing preserves native false and zero and leaves semantics to Ingestion" do
      assert LabelValue.parse_input(%{value_type: "boolean"}, "false") == {:ok, false}
      assert LabelValue.parse_input(%{value_type: "boolean"}, "true") == {:ok, true}
      assert LabelValue.parse_input(%{value_type: "boolean"}, "other") == :error
      assert LabelValue.parse_input(%{value_type: "scale"}, "0") == {:ok, 0}
      assert LabelValue.parse_input(%{value_type: "scale"}, "-0.5") == {:ok, -0.5}
      assert LabelValue.parse_input(%{value_type: "scale"}, "1e2") == {:ok, 100.0}
      assert LabelValue.parse_input(%{value_type: "scale"}, "1oops") == :error
      assert LabelValue.parse_input(%{value_type: "scale"}, "") == {:ok, nil}
      assert LabelValue.parse_input(%{value_type: "scale"}, "999") == {:ok, 999}
    end
  end

  defp query_html(html, selector),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  setup do
    user = super_admin_fixture(%{must_change_password: false}) |> Zaq.Repo.preload(:role)
    actor = %{user_id: user.id}

    {:ok, label} =
      Labels.save_definition(
        %{name: "Security", description: "<script>unsafe</script>", targets: ["document"]},
        actor
      )

    {:ok, document} = Document.create(%{source: "editor-#{System.unique_integer([:positive])}"})
    %{user: user, actor: actor, label: label, resource: %{type: "document", id: document.id}}
  end

  test "enters a value, offers permitted existing values and saves a value-only change", ctx do
    {:ok, other} = Document.create(%{source: "suggested-city"})

    assert {:ok, _} =
             Labels.edit_resource(
               %{type: "document", id: other.id},
               [%{label_id: ctx.label.id, operation: "add", expected_version: 0, value: "Paris"}],
               ctx.actor
             )

    {:ok, view, _} =
      live_isolated(ctx.conn, ZaqWeb.LabelEditorHost,
        session: %{"user" => ctx.user, "resource" => ctx.resource}
      )

    view |> form("#search-resource-labels", query: "Security") |> render_change()
    view |> element("#label-option-#{ctx.label.id}") |> render_click()

    view
    |> with_target("#test-label-editor")
    |> render_hook(
      "search_label_values",
      %{"label_id" => to_string(ctx.label.id), "query" => ""}
    )

    assert has_element?(
             view,
             "#label-value-#{ctx.label.id}[phx-hook=SearchableSelect] [data-select-value=Paris]"
           )

    view
    |> form("#label-value-form-#{ctx.label.id}")
    |> render_change(%{"label_id" => to_string(ctx.label.id), "value" => "Paris"})

    refute Zaq.Repo.get_by(DocumentAssignment, document_id: ctx.resource.id)
    view |> element("#save-resource-labels") |> render_click()
    assert Zaq.Repo.get_by!(DocumentAssignment, document_id: ctx.resource.id).value == "Paris"

    {:ok, view, _} =
      live_isolated(ctx.conn, ZaqWeb.LabelEditorHost,
        session: %{"user" => ctx.user, "resource" => ctx.resource}
      )

    assert has_element?(view, "#label-value-#{ctx.label.id} input[value=Paris]")

    view
    |> with_target("#test-label-editor")
    |> render_hook(
      "create_label_value",
      %{"label_id" => to_string(ctx.label.id), "name" => "London"}
    )

    view |> element("#save-resource-labels") |> render_click()
    assert Zaq.Repo.get_by!(DocumentAssignment, document_id: ctx.resource.id).value == "London"
  end

  test "create events change only the targeted label and remain staged until Save", ctx do
    {:ok, other} = Labels.save_definition(%{name: "Department", targets: ["document"]}, ctx.actor)

    {:ok, view, _} =
      live_isolated(ctx.conn, ZaqWeb.LabelEditorHost,
        session: %{"user" => ctx.user, "resource" => ctx.resource}
      )

    for label <- [ctx.label, other] do
      view |> form("#search-resource-labels", query: label.name) |> render_change()
      view |> element("#label-option-#{label.id}") |> render_click()
    end

    view
    |> with_target("#test-label-editor")
    |> render_hook(
      "create_label_value",
      %{"label_id" => to_string(other.id), "name" => "Finance"}
    )

    assert has_element?(view, "#label-value-#{other.id} input[value=Finance]")
    assert has_element?(view, "#label-value-#{ctx.label.id} input[value='']")
    refute Zaq.Repo.get_by(DocumentAssignment, document_id: ctx.resource.id)
    view |> element("#save-resource-labels") |> render_click()

    assert Zaq.Repo.get_by!(DocumentAssignment, document_id: ctx.resource.id, label_id: other.id).value ==
             "Finance"

    assert Zaq.Repo.get_by!(DocumentAssignment,
             document_id: ctx.resource.id,
             label_id: ctx.label.id
           ).value == nil
  end

  test "shared picker can clear an existing value without removing the label", ctx do
    assert {:ok, _} =
             Labels.edit_resource(
               ctx.resource,
               [%{label_id: ctx.label.id, operation: "add", expected_version: 0, value: "Paris"}],
               ctx.actor
             )

    {:ok, view, _} =
      live_isolated(ctx.conn, ZaqWeb.LabelEditorHost,
        session: %{"user" => ctx.user, "resource" => ctx.resource}
      )

    assert has_element?(view, "#label-value-#{ctx.label.id} [data-select-option='No value']")

    view
    |> form("#label-value-form-#{ctx.label.id}")
    |> render_change(%{"label_id" => to_string(ctx.label.id), "value" => ""})

    view |> element("#save-resource-labels") |> render_click()

    assert %{selected: true, value: nil} =
             Zaq.Repo.get_by!(DocumentAssignment, document_id: ctx.resource.id)
  end

  test "cancel discards a staged value change and chips show the saved value", ctx do
    assert {:ok, _} =
             Labels.edit_resource(
               ctx.resource,
               [%{label_id: ctx.label.id, operation: "add", expected_version: 0, value: "Paris"}],
               ctx.actor
             )

    {:ok, view, _} =
      live_isolated(ctx.conn, ZaqWeb.LabelEditorHost,
        session: %{"user" => ctx.user, "resource" => ctx.resource}
      )

    view
    |> form("#label-value-form-#{ctx.label.id}")
    |> render_change(%{"label_id" => to_string(ctx.label.id), "value" => "London"})

    view |> element("button[phx-click=close_label_editor]", "Cancel") |> render_click()
    assert Zaq.Repo.get_by!(DocumentAssignment, document_id: ctx.resource.id).value == "Paris"

    html =
      render_component(&LabelChips.label_chips/1,
        labels: [%{id: ctx.label.id, name: "Location", value: "Paris"}],
        resource_id: ctx.resource.id
      )

    assert html =~ "Location: Paris"
  end

  test "stages changes, cancels without writing and escapes category descriptions", %{
    conn: conn,
    user: user,
    resource: resource,
    label: label
  } do
    {:ok, view, _html} =
      live_isolated(conn, ZaqWeb.LabelEditorHost,
        session: %{"user" => user, "resource" => resource}
      )

    html = view |> form("#search-resource-labels", query: "Security") |> render_change()
    assert html =~ "&lt;script&gt;"
    view |> element("#label-option-#{label.id}") |> render_click()
    assert has_element?(view, "#label-option-#{label.id}[checked]")
    refute Zaq.Repo.get_by(DocumentAssignment, document_id: resource.id)
    view |> element("button[phx-click=close_label_editor]", "Cancel") |> render_click()
    refute has_element?(view, "#resource-label-modal")
    refute Zaq.Repo.get_by(DocumentAssignment, document_id: resource.id)
  end

  test "saves an inclusion then a removal as explicit manual exclusion", %{
    conn: conn,
    user: user,
    resource: resource,
    label: label
  } do
    {:ok, view, _} =
      live_isolated(conn, ZaqWeb.LabelEditorHost,
        session: %{"user" => user, "resource" => resource}
      )

    view |> form("#search-resource-labels", query: "Security") |> render_change()
    view |> element("#label-option-#{label.id}") |> render_click()
    view |> element("#save-resource-labels") |> render_click()
    assert has_element?(view, "#labels-saved")
    assert Zaq.Repo.get_by!(DocumentAssignment, document_id: resource.id).selected

    {:ok, view, _} =
      live_isolated(conn, ZaqWeb.LabelEditorHost,
        session: %{"user" => user, "resource" => resource}
      )

    view |> element("#label-option-#{label.id}") |> render_click()
    view |> element("#save-resource-labels") |> render_click()
    assert has_element?(view, "#labels-saved")
    assignment = Zaq.Repo.get_by!(DocumentAssignment, document_id: resource.id)
    assert assignment.selected == false
    assert assignment.origin == :manual
  end

  test "stale save retains staging until explicit reload", %{
    conn: conn,
    user: user,
    actor: actor,
    resource: resource,
    label: label
  } do
    {:ok, view, _} =
      live_isolated(conn, ZaqWeb.LabelEditorHost,
        session: %{"user" => user, "resource" => resource}
      )

    view |> form("#search-resource-labels", query: "Security") |> render_change()
    view |> element("#label-option-#{label.id}") |> render_click()

    {:ok, _} =
      Labels.edit_resource(
        resource,
        [%{label_id: label.id, expected_version: 0, operation: "remove"}],
        actor
      )

    view |> element("#save-resource-labels") |> render_click()
    assert has_element?(view, "[role=alert]", "changed")
    assert has_element?(view, "#label-option-#{label.id}[checked]")
    view |> element("button[phx-click=reload_labels]") |> render_click()
    refute has_element?(view, "#label-option-#{label.id}[checked]")
    refute has_element?(view, "[role=alert]")
  end

  test "shows assigned labels separately and searches available names and descriptions", %{
    conn: conn,
    user: user,
    actor: actor,
    resource: resource,
    label: label
  } do
    {:ok, architecture} =
      Labels.save_definition(
        %{name: "Architecture", description: "Scalability", targets: ["document"]},
        actor
      )

    {:ok, view, _} =
      live_isolated(conn, ZaqWeb.LabelEditorHost,
        session: %{"user" => user, "resource" => resource}
      )

    refute has_element?(view, "#active-resource-labels input")
    refute has_element?(view, "#available-resource-labels")
    view |> form("#search-resource-labels", query: "SCALABILITY") |> render_change()
    assert has_element?(view, "#available-resource-labels #label-option-#{architecture.id}")
    refute has_element?(view, "#available-resource-labels #label-option-#{label.id}")
    view |> element("#label-option-#{architecture.id}") |> render_click()
    assert has_element?(view, "#active-resource-labels #label-option-#{architecture.id}[checked]")
    refute has_element?(view, "#available-resource-labels #label-option-#{architecture.id}")
    refute has_element?(view, "#available-resource-labels")
    assert has_element?(view, "#resource-label-search[value='']")
    view |> form("#search-resource-labels", query: "missing") |> render_change()
    assert has_element?(view, "#available-resource-labels", "No matching labels.")
    assert has_element?(view, "#active-resource-labels #label-option-#{architecture.id}[checked]")
    refute Zaq.Repo.get_by(DocumentAssignment, document_id: resource.id)
  end
end

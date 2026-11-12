defmodule ZaqWeb.Components.LabelEditorTest do
  use ZaqWeb.ConnCase, async: true
  use ExUnitProperties
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  alias Zaq.Ingestion.{Document, Labels}
  alias Zaq.Ingestion.Labels.Assignment
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
        %{
          name: "Security",
          description: "<script>unsafe</script>",
          resources: ["document"],
          value_type: "options",
          value_config: Zaq.LabelFixtures.option_config(["Paris", "London", "Unspecified"])
        },
        actor
      )

    {:ok, document} = Document.create(%{source: "editor-#{System.unique_integer([:positive])}"})
    %{user: user, actor: actor, label: label, resource: %{type: "document", id: document.id}}
  end

  test "chooses definition-owned values and saves a value-only change", ctx do
    {:ok, view, _} =
      live_isolated(ctx.conn, ZaqWeb.LabelEditorHost,
        session: %{"user" => ctx.user, "resource" => ctx.resource}
      )

    view |> form("#search-resource-labels", query: "Security") |> render_change()
    view |> element("#label-option-#{ctx.label.id}") |> render_click()

    assert has_element?(
             view,
             "#label-value-#{ctx.label.id}[phx-hook=SearchableSelect] [data-select-value=Paris]"
           )

    view
    |> form("#label-value-form-#{ctx.label.id}")
    |> render_change(%{"label_id" => to_string(ctx.label.id), "value" => "Paris"})

    refute Zaq.Repo.get_by(Assignment, document_id: ctx.resource.id)
    view |> element("#save-resource-labels") |> render_click()
    assert Zaq.Repo.get_by!(Assignment, document_id: ctx.resource.id).value == "Paris"

    {:ok, view, _} =
      live_isolated(ctx.conn, ZaqWeb.LabelEditorHost,
        session: %{"user" => ctx.user, "resource" => ctx.resource}
      )

    assert has_element?(view, "#label-value-#{ctx.label.id} input[value=Paris]")

    view
    |> with_target("#test-label-editor")
    |> render_hook(
      "change_label_value",
      %{"label_id" => to_string(ctx.label.id), "value" => "London"}
    )

    view |> element("#save-resource-labels") |> render_click()
    assert Zaq.Repo.get_by!(Assignment, document_id: ctx.resource.id).value == "London"
  end

  test "typed value changes affect only the targeted label and remain staged until Save", ctx do
    {:ok, other} =
      Labels.save_definition(
        %{
          name: "Department",
          resources: ["document"],
          value_type: "options",
          value_config: Zaq.LabelFixtures.option_config(["Finance"])
        },
        ctx.actor
      )

    {:ok, view, _} =
      live_isolated(ctx.conn, ZaqWeb.LabelEditorHost,
        session: %{"user" => ctx.user, "resource" => ctx.resource}
      )

    for label <- [ctx.label, other] do
      view |> form("#search-resource-labels", query: label.name) |> render_change()
      view |> element("#label-option-#{label.id}") |> render_click()
    end

    view
    |> form("#label-value-form-#{ctx.label.id}")
    |> render_change(%{"label_id" => to_string(ctx.label.id), "value" => "Unspecified"})

    view
    |> with_target("#test-label-editor")
    |> render_hook(
      "change_label_value",
      %{"label_id" => to_string(other.id), "value" => "Finance"}
    )

    assert has_element?(view, "#label-value-#{other.id} input[value=Finance]")
    assert has_element?(view, "#label-value-#{ctx.label.id} input[value='Unspecified']")
    refute Zaq.Repo.get_by(Assignment, document_id: ctx.resource.id)
    view |> element("#save-resource-labels") |> render_click()

    assert Zaq.Repo.get_by!(Assignment, document_id: ctx.resource.id, label_id: other.id).value ==
             "Finance"

    assert Zaq.Repo.get_by!(Assignment,
             document_id: ctx.resource.id,
             label_id: ctx.label.id
           ).value == "Unspecified"
  end

  test "manual values are required and explicit unspecified retains the assignment", ctx do
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

    refute has_element?(view, "#label-value-#{ctx.label.id} [data-select-option='No value']")
    refute has_element?(view, "#label-value-#{ctx.label.id} [data-select-create]")

    view
    |> form("#label-value-form-#{ctx.label.id}")
    |> render_change(%{"label_id" => to_string(ctx.label.id), "value" => ""})

    view |> element("#save-resource-labels") |> render_click()

    assert has_element?(view, "[role=alert]", "configured choices")

    assert %{state: :assigned, value: "Paris"} =
             Zaq.Repo.get_by!(Assignment, document_id: ctx.resource.id)

    view
    |> form("#label-value-form-#{ctx.label.id}")
    |> render_change(%{"label_id" => to_string(ctx.label.id), "value" => "Unspecified"})

    view |> element("#save-resource-labels") |> render_click()

    assert %{state: :assigned, value: "Unspecified"} =
             Zaq.Repo.get_by!(Assignment, document_id: ctx.resource.id)
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
    assert Zaq.Repo.get_by!(Assignment, document_id: ctx.resource.id).value == "Paris"

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
    refute Zaq.Repo.get_by(Assignment, document_id: resource.id)
    view |> element("button[phx-click=close_label_editor]", "Cancel") |> render_click()
    refute has_element?(view, "#resource-label-modal")
    refute Zaq.Repo.get_by(Assignment, document_id: resource.id)
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

    view
    |> form("#label-value-form-#{label.id}")
    |> render_change(%{"label_id" => to_string(label.id), "value" => "Paris"})

    view |> element("#save-resource-labels") |> render_click()
    assert has_element?(view, "#labels-saved")
    assert Zaq.Repo.get_by!(Assignment, document_id: resource.id).state == :assigned

    {:ok, view, _} =
      live_isolated(conn, ZaqWeb.LabelEditorHost,
        session: %{"user" => user, "resource" => resource}
      )

    view |> element("#label-option-#{label.id}") |> render_click()
    view |> element("#save-resource-labels") |> render_click()
    assert has_element?(view, "#labels-saved")
    assignment = Zaq.Repo.get_by!(Assignment, document_id: resource.id)
    assert assignment.state == :excluded
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

    view
    |> form("#label-value-form-#{label.id}")
    |> render_change(%{"label_id" => to_string(label.id), "value" => "Paris"})

    {:ok, _} =
      Labels.edit_resource(
        resource,
        [%{label_id: label.id, expected_version: 0, operation: "remove"}],
        actor
      )

    view |> element("#save-resource-labels") |> render_click()
    assert has_element?(view, "[role=alert]", "changed")
    assert has_element?(view, "#label-option-#{label.id}[checked]")
    assert has_element?(view, "#label-value-#{label.id} input[value=Paris]")
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
        %{name: "Architecture", description: "Scalability", resources: ["document"]},
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
    refute Zaq.Repo.get_by(Assignment, document_id: resource.id)
  end

  test "false and zero remain native and unchanged selections do not rewrite assignments", ctx do
    for {type, config, previous, wire, expected} <- [
          {"boolean", %{}, true, "false", false},
          {"scale", %{"min" => 0, "max" => 10, "increment" => 2}, 2, "0", 0}
        ] do
      {:ok, label} =
        Zaq.LabelFixtures.label_definition(ctx.actor, %{
          name: "Native #{type}",
          resources: ["document"],
          value_type: type,
          value_config: config
        })

      assert {:ok, _} =
               Labels.edit_resource(
                 ctx.resource,
                 [%{label_id: label.id, operation: "add", value: previous, expected_version: 0}],
                 ctx.actor
               )

      {:ok, view, _} =
        live_isolated(ctx.conn, ZaqWeb.LabelEditorHost,
          session: %{"user" => ctx.user, "resource" => ctx.resource}
        )

      view
      |> form("#label-value-form-#{label.id}")
      |> render_change(%{"label_id" => to_string(label.id), "value" => wire})

      assert Zaq.Repo.get_by!(Assignment, document_id: ctx.resource.id, label_id: label.id).value ===
               previous

      view |> element("#save-resource-labels") |> render_click()
      assignment = Zaq.Repo.get_by!(Assignment, document_id: ctx.resource.id, label_id: label.id)
      assert assignment.value === expected
      assert assignment.lock_version == 2

      {:ok, unchanged, _} =
        live_isolated(ctx.conn, ZaqWeb.LabelEditorHost,
          session: %{"user" => ctx.user, "resource" => ctx.resource}
        )

      unchanged |> element("#save-resource-labels") |> render_click()
      assert Zaq.Repo.reload!(assignment) == assignment
      refute Zaq.Repo.get_by(Assignment, document_id: ctx.resource.id, label_id: ctx.label.id)
    end
  end

  test "automatic missing values stay pending until an explicit typed manual decision", ctx do
    {:ok, label} =
      Zaq.LabelFixtures.label_definition(ctx.actor, %{
        name: "Automatic review",
        resources: ["document"],
        assignment_type: "automatic"
      })

    {:ok, view, _} =
      live_isolated(ctx.conn, ZaqWeb.LabelEditorHost,
        session: %{"user" => ctx.user, "resource" => ctx.resource}
      )

    view |> form("#search-resource-labels", query: "Automatic") |> render_change()
    view |> element("#label-option-#{label.id}") |> render_click()
    refute Zaq.Repo.get_by(Assignment, document_id: ctx.resource.id)
    view |> element("#save-resource-labels") |> render_click()

    assert %{state: :pending, origin: :automatic, value: nil, lock_version: 1} =
             Zaq.Repo.get_by!(Assignment, document_id: ctx.resource.id, label_id: label.id)

    {:ok, pending, _} =
      live_isolated(ctx.conn, ZaqWeb.LabelEditorHost,
        session: %{"user" => ctx.user, "resource" => ctx.resource}
      )

    assert has_element?(pending, "#active-resource-labels", "Pending automatic")
    pending |> element("#save-resource-labels") |> render_click()

    assert Zaq.Repo.get_by!(Assignment, document_id: ctx.resource.id, label_id: label.id).lock_version ==
             1

    {:ok, manual, _} =
      live_isolated(ctx.conn, ZaqWeb.LabelEditorHost,
        session: %{"user" => ctx.user, "resource" => ctx.resource}
      )

    manual
    |> form("#label-value-form-#{label.id}")
    |> render_change(%{"label_id" => to_string(label.id), "value" => "false"})

    manual |> element("#save-resource-labels") |> render_click()

    assert %{state: :assigned, origin: :manual, value: false} =
             Zaq.Repo.get_by!(Assignment, document_id: ctx.resource.id, label_id: label.id)
  end

  test "a rejected option rolls back other edits and retains both staged values for correction",
       ctx do
    {:ok, boolean} =
      Zaq.LabelFixtures.label_definition(ctx.actor, %{name: "Approval", resources: ["document"]})

    assert {:ok, _} =
             Labels.edit_resource(
               ctx.resource,
               [
                 %{label_id: boolean.id, operation: "add", value: true, expected_version: 0},
                 %{label_id: ctx.label.id, operation: "add", value: "Paris", expected_version: 0}
               ],
               ctx.actor
             )

    {:ok, view, _} =
      live_isolated(ctx.conn, ZaqWeb.LabelEditorHost,
        session: %{"user" => ctx.user, "resource" => ctx.resource}
      )

    view
    |> form("#label-value-form-#{boolean.id}")
    |> render_change(%{"label_id" => to_string(boolean.id), "value" => "false"})

    view
    |> form("#label-value-form-#{ctx.label.id}")
    |> render_change(%{"label_id" => to_string(ctx.label.id), "value" => "unknown-option"})

    view |> element("#save-resource-labels") |> render_click()
    assert has_element?(view, "[role=alert]", "configured choices")
    assert has_element?(view, "#label-value-#{boolean.id} input[value=false]")
    assert has_element?(view, "#label-value-#{ctx.label.id} input[value=unknown-option]")

    assert %{value: true, lock_version: 1} =
             Zaq.Repo.get_by!(Assignment, document_id: ctx.resource.id, label_id: boolean.id)

    assert %{value: "Paris", lock_version: 1} =
             Zaq.Repo.get_by!(Assignment, document_id: ctx.resource.id, label_id: ctx.label.id)

    view
    |> form("#label-value-form-#{ctx.label.id}")
    |> render_change(%{"label_id" => to_string(ctx.label.id), "value" => "London"})

    view |> element("#save-resource-labels") |> render_click()

    assert Zaq.Repo.get_by!(Assignment, document_id: ctx.resource.id, label_id: boolean.id).value ==
             false

    assert Zaq.Repo.get_by!(Assignment, document_id: ctx.resource.id, label_id: ctx.label.id).value ==
             "London"
  end

  test "unserializable input blocks saving the previous value until corrected", ctx do
    {:ok, label} =
      Zaq.LabelFixtures.label_definition(ctx.actor, %{
        name: "Score",
        resources: ["document"],
        value_type: "scale",
        value_config: %{"min" => 0, "max" => 10, "increment" => 2}
      })

    assert {:ok, _} =
             Labels.edit_resource(
               ctx.resource,
               [%{label_id: label.id, operation: "add", value: 2, expected_version: 0}],
               ctx.actor
             )

    {:ok, view, _} =
      live_isolated(ctx.conn, ZaqWeb.LabelEditorHost,
        session: %{"user" => ctx.user, "resource" => ctx.resource}
      )

    view
    |> with_target("#test-label-editor")
    |> render_hook("change_label_value", %{
      "label_id" => to_string(label.id),
      "value" => "invalid-number"
    })

    view |> element("#save-resource-labels") |> render_click()
    assert has_element?(view, "[role=alert]", "configured choices")
    refute has_element?(view, "#labels-saved")

    assert %{value: 2, lock_version: 1} =
             Zaq.Repo.get_by!(Assignment, document_id: ctx.resource.id, label_id: label.id)

    view |> form("#label-value-form-#{label.id}", value: "0") |> render_change()
    view |> element("#save-resource-labels") |> render_click()

    assert %{value: 0, lock_version: 2} =
             Zaq.Repo.get_by!(Assignment, document_id: ctx.resource.id, label_id: label.id)
  end

  test "read-only and missing actors cannot mutate through forged editor events", ctx do
    assert {:ok, _} =
             Labels.edit_resource(
               ctx.resource,
               [%{label_id: ctx.label.id, operation: "add", value: "Paris", expected_version: 0}],
               ctx.actor
             )

    document = Zaq.Repo.get!(Document, ctx.resource.id)
    assert {:ok, _} = Zaq.Permissions.grant_public(document)
    staff = staff_fixture(%{must_change_password: false}) |> Zaq.Repo.preload(:role)

    {:ok, view, _} =
      live_isolated(ctx.conn, ZaqWeb.LabelEditorHost,
        session: %{"user" => staff, "resource" => ctx.resource}
      )

    assert has_element?(view, "#save-resource-labels[disabled]")
    assert has_element?(view, "#label-value-#{ctx.label.id}-trigger[disabled]")
    assert has_element?(view, "#resource-label-modal", "read-only access")

    view
    |> with_target("#test-label-editor")
    |> render_hook("change_label_value", %{
      "label_id" => to_string(ctx.label.id),
      "value" => "London"
    })

    view |> with_target("#test-label-editor") |> render_hook("save_labels", %{})
    assert Zaq.Repo.get_by!(Assignment, document_id: ctx.resource.id).value == "Paris"
    refute has_element?(view, "#labels-saved")

    {:ok, missing, _} =
      live_isolated(ctx.conn, ZaqWeb.LabelEditorHost,
        session: %{"user" => nil, "resource" => ctx.resource}
      )

    assert has_element?(missing, "#save-resource-labels[disabled]")
    assert has_element?(missing, "[role=alert]", "permission")
  end

  test "revoking update access after opening retains staging until explicit reload", ctx do
    assert {:ok, _} =
             Labels.edit_resource(
               ctx.resource,
               [%{label_id: ctx.label.id, operation: "add", value: "Paris", expected_version: 0}],
               ctx.actor
             )

    document = Zaq.Repo.get!(Document, ctx.resource.id)
    everyone = Zaq.Permissions.everyone_team_id()

    assert {:ok, _} =
             Zaq.Permissions.grant(document, %{
               team_id: everyone,
               access_rights: ["read", "update"]
             })

    staff = staff_fixture(%{must_change_password: false}) |> Zaq.Repo.preload(:role)

    {:ok, view, _} =
      live_isolated(ctx.conn, ZaqWeb.LabelEditorHost,
        session: %{"user" => staff, "resource" => ctx.resource}
      )

    refute has_element?(view, "#save-resource-labels[disabled]")

    view
    |> form("#label-value-form-#{ctx.label.id}")
    |> render_change(%{"label_id" => to_string(ctx.label.id), "value" => "London"})

    assert {:ok, _} =
             Zaq.Permissions.grant(document, %{team_id: everyone, access_rights: ["read"]})

    view |> element("#save-resource-labels") |> render_click()
    assert has_element?(view, "[role=alert]", "permission")
    assert has_element?(view, "#label-value-#{ctx.label.id} input[value=London]")

    assert %{value: "Paris", lock_version: 1} =
             Zaq.Repo.get_by!(Assignment, document_id: ctx.resource.id)

    view |> element("button[phx-click=reload_labels]") |> render_click()
    assert has_element?(view, "#save-resource-labels[disabled]")
    assert has_element?(view, "#label-value-#{ctx.label.id} input[value=Paris]")
    refute has_element?(view, "[role=alert]")
  end
end

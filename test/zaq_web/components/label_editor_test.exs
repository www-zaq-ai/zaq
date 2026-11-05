defmodule ZaqWeb.Components.LabelEditorTest do
  use ZaqWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  alias Zaq.Ingestion.{Document, Labels}
  alias Zaq.Ingestion.Labels.DocumentAssignment
  alias ZaqWeb.Components.DesignSystem.LabelChips

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

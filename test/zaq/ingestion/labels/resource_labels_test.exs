defmodule Zaq.Ingestion.Labels.ResourceLabelsTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  import Zaq.AccountsFixtures
  import Zaq.LabelFixtures

  alias Zaq.Accounts.People
  alias Zaq.Ingestion.{Document, Labels}
  alias Zaq.Ingestion.Labels.{AssignmentValue, DocumentAssignment, ResourceLabels}
  alias Zaq.Permissions

  describe "manual assignments" do
    setup do
      role = role_fixture(%{name: "super_admin"})
      user = user_fixture(%{role_id: role.id, must_change_password: false})
      {:ok, document} = Document.create(%{source: "labels-#{System.unique_integer([:positive])}"})

      %{actor: %{user_id: user.id}, document: document}
    end

    test "manual exclusion, optimistic edits and atomic rollback", %{
      actor: actor,
      document: document
    } do
      {:ok, label} = label_definition(actor)
      resource = %{type: "document", id: document.id}

      assert {:ok, _} =
               Labels.edit_resource(
                 resource,
                 [%{label_id: label.id, operation: "remove", expected_version: 0}],
                 actor
               )

      assignment = Repo.get_by!(DocumentAssignment, document_id: document.id, label_id: label.id)
      assert assignment.selected == false
      assert assignment.origin == :manual

      assert {:error, :stale} =
               Labels.edit_resource(
                 resource,
                 [%{label_id: label.id, operation: "add", expected_version: 0}],
                 actor
               )

      assert {:error, :not_found} =
               Labels.edit_resource(
                 resource,
                 [
                   %{
                     label_id: label.id,
                     operation: "add",
                     expected_version: assignment.lock_version
                   },
                   %{label_id: 0, operation: "add", expected_version: 0}
                 ],
                 actor
               )

      refute Repo.reload!(assignment).selected

      assert {:error, :automation_unavailable} =
               Labels.edit_resource(
                 resource,
                 [
                   %{
                     label_id: label.id,
                     operation: "reset_automatic",
                     expected_version: assignment.lock_version
                   }
                 ],
                 actor
               )
    end

    property "unsupported resource types never resolve numeric IDs" do
      check all(type <- string(:alphanumeric, min_length: 1), type not in ["document", "chunk"]) do
        assert {:error, :invalid_resource} = ResourceLabels.resolve(%{type: type, id: 1})
      end
    end
  end

  describe "assignment values and suggestions" do
    setup do
      user = super_admin_fixture(%{must_change_password: false})
      actor = %{user_id: user.id}

      {:ok, label} =
        Labels.save_definition(%{name: "Location", targets: ["document", "chunk"]}, actor)

      {:ok, first} = Document.create(%{source: "value-first"})
      {:ok, second} = Document.create(%{source: "value-second"})
      %{actor: actor, label: label, first: first, second: second}
    end

    test "values belong to assignments and value-only edits use optimistic versions", ctx do
      assert {:ok, _} = edit(ctx, ctx.first, " Paris ", 0)
      assert {:ok, _} = edit(ctx, ctx.second, "London", 0)

      assert {:ok, %{labels: [%{value: "Paris", expected_version: 1}]}} =
               Labels.resource_editor(resource(ctx.first), ctx.actor)

      assert {:ok, chips} =
               Labels.document_chips([ctx.first.source, ctx.second.source], ctx.actor)

      assert chips[ctx.first.source].chips == [
               %{id: ctx.label.id, name: "Location", value: "Paris"}
             ]

      assert chips[ctx.second.source].chips == [
               %{id: ctx.label.id, name: "Location", value: "London"}
             ]

      assert {:ok, _} = edit(ctx, ctx.first, "Lyon", 1)
      assert {:error, :stale} = edit(ctx, ctx.first, "Berlin", 1)
      assert Repo.get_by!(DocumentAssignment, document_id: ctx.first.id).value == "Lyon"

      assert {:ok, ["London", "Lyon"]} =
               Labels.value_suggestions(resource(ctx.first), ctx.label.id, "", ctx.actor)
    end

    test "invalid values fail the batch and removal clears the old value", ctx do
      assert {:ok, _} = edit(ctx, ctx.first, "Paris", 0)

      for invalid <- [123, %{}, String.duplicate("x", 201)] do
        assert {:error, :invalid_value} = edit(ctx, ctx.first, invalid, 1)
        assert Repo.get_by!(DocumentAssignment, document_id: ctx.first.id).value == "Paris"
      end

      assert {:ok, _} =
               Labels.edit_resource(
                 resource(ctx.first),
                 [%{label_id: ctx.label.id, operation: "remove", expected_version: 1}],
                 ctx.actor
               )

      assert %{selected: false, value: nil} =
               Repo.get_by!(DocumentAssignment, document_id: ctx.first.id)

      assert {:ok, []} =
               Labels.value_suggestions(resource(ctx.first), ctx.label.id, "", ctx.actor)
    end

    test "suggestions enforce source-document read permission and ignore forged bypass", ctx do
      assert {:ok, _} = edit(ctx, ctx.first, "Paris", 0)
      assert {:ok, _} = edit(ctx, ctx.second, "Private city", 0)
      staff = staff_fixture(%{must_change_password: false})
      {:ok, person} = People.create_person(%{full_name: "Value reader"})
      actor = %{user_id: staff.id, person_id: person.id, skip_permissions: true}
      {:ok, _} = Permissions.grant(ctx.first, %{person_id: person.id, access_rights: ["read"]})
      {:ok, _} = Permissions.grant(ctx.second, %{person_id: person.id, access_rights: ["update"]})
      request = %{resource: resource(ctx.first), label_id: ctx.label.id, query: "pA"}
      assert {:ok, ["Paris"]} = label_event(:label_value_suggestions, request, actor)

      assert {:error, :forbidden} =
               Labels.value_suggestions(resource(ctx.second), ctx.label.id, "", actor)

      assert {:error, :unauthorized} =
               Labels.value_suggestions(resource(ctx.first), ctx.label.id, "", nil)

      assert {:error, :forbidden} =
               Labels.edit_resource(
                 resource(ctx.first),
                 [
                   %{
                     label_id: ctx.label.id,
                     operation: "add",
                     expected_version: 1,
                     value: "Changed"
                   }
                 ],
                 actor
               )
    end

    test "empty values remain compatible and normalized suggestions are distinct", ctx do
      assert {:ok, _} = edit(ctx, ctx.first, " Cafe\u0301 ", 0)
      assert {:ok, _} = edit(ctx, ctx.second, "Café", 0)

      assert {:ok, ["Café"]} =
               Labels.value_suggestions(resource(ctx.first), ctx.label.id, "", ctx.actor)

      assert {:ok, _} = edit(ctx, ctx.first, "   ", 1)
      assert Repo.get_by!(DocumentAssignment, document_id: ctx.first.id).value == nil
    end

    test "suggestions deduplicate and limit after filtering readable documents", ctx do
      staff = staff_fixture(%{must_change_password: false})
      {:ok, person} = People.create_person(%{full_name: "Limited reader"})
      actor = %{user_id: staff.id, person_id: person.id}

      for n <- 1..25 do
        {:ok, document} = Document.create(%{source: "limited-city-#{n}"})

        assert {:ok, _} =
                 edit(ctx, document, "City #{String.pad_leading(to_string(n), 2, "0")}", 0)

        {:ok, _} = Permissions.grant(document, %{person_id: person.id, access_rights: ["read"]})
      end

      {:ok, _} = Permissions.grant(ctx.first, %{person_id: person.id, access_rights: ["read"]})
      assert {:ok, _} = edit(ctx, ctx.second, "AAA private", 0)

      assert {:ok, values} =
               Labels.value_suggestions(resource(ctx.first), ctx.label.id, "", actor)

      assert length(values) == 20
      assert hd(values) == "City 01"
      assert List.last(values) == "City 20"
      refute "AAA private" in values
    end

    property "normalizing a valid value is idempotent and trims whitespace" do
      check all(value <- string(:alphanumeric, max_length: 100)) do
        normalized = AssignmentValue.normalize("  #{value}  ")
        assert AssignmentValue.normalize(normalized) == normalized
        assert normalized == if(value == "", do: nil, else: value)
      end
    end
  end

  describe "resource events and permissions" do
    test "validated Actions and read projections share authoritative definitions and assignments" do
      user = super_admin_fixture(%{must_change_password: false})
      actor = %{user_id: user.id}

      assert {:ok, label} =
               label_event(
                 :save_label_definition,
                 %{attrs: %{name: "Architecture", targets: ["document"]}},
                 actor
               )

      {:ok, document} = Document.create(%{source: "label-events"})
      resource = %{type: "document", id: document.id}

      assert {:ok, %{labels: [%{selected: true}]}} =
               label_event(
                 :edit_resource_labels,
                 %{
                   resource: resource,
                   edits: [%{label_id: label.id, expected_version: 0, operation: "add"}]
                 },
                 actor
               )

      assert {:ok, [%{id: id}]} = label_event(:list_labels, %{}, actor)
      assert id == label.id

      assert {:ok, %{editable?: true}} =
               label_event(:get_resource_labels, %{resource: resource}, actor)

      assert {:ok, chips} =
               label_event(:document_label_chips, %{sources: [document.source]}, actor)

      assert chips[document.source].chips == [%{id: id, name: "Architecture"}]
      assert {:error, _} = label_event(:edit_resource_labels, %{}, actor)
    end

    test "document permissions apply to reads and writes; forged bypass is ineffective" do
      user = staff_fixture(%{must_change_password: false})
      {:ok, person} = People.create_person(%{full_name: "Label reader"})
      actor = %{user_id: user.id, person_id: person.id, skip_permissions: true}
      {:ok, document} = Document.create(%{source: "private-label-events"})
      resource = %{type: "document", id: document.id}
      assert {:error, :forbidden} = Labels.resource_editor(resource, actor)
      {:ok, _} = Permissions.grant(document, %{person_id: person.id, access_rights: ["read"]})
      assert {:ok, %{editable?: false}} = Labels.resource_editor(resource, actor)
      assert {:error, :forbidden} = Labels.edit_resource(resource, [], actor)
      assert {:ok, %{}} = Labels.document_chips([document.source], %{user_id: user.id})
    end

    test "batch chips require read rights rather than any principal grant" do
      user = staff_fixture(%{must_change_password: false})
      {:ok, person} = People.create_person(%{full_name: "Update-only editor"})
      actor = %{user_id: user.id, person_id: person.id}
      {:ok, document} = Document.create(%{source: "update-only-labels"})
      {:ok, _} = Permissions.grant(document, %{person_id: person.id, access_rights: ["update"]})

      assert {:error, :forbidden} =
               Labels.resource_editor(%{type: "document", id: document.id}, actor)

      assert Labels.document_chips([document.source], actor) == {:ok, %{}}
    end
  end

  defp edit(ctx, document, value, version) do
    label_event(
      :edit_resource_labels,
      %{
        resource: resource(document),
        edits: [
          %{label_id: ctx.label.id, operation: "add", expected_version: version, value: value}
        ]
      },
      ctx.actor
    )
  end

  defp resource(document), do: %{type: "document", id: document.id}
end

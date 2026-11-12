defmodule Zaq.Ingestion.Labels.ResourceLabelsTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  import Zaq.AccountsFixtures
  import Zaq.LabelFixtures

  alias Zaq.Accounts.People
  alias Zaq.Ingestion.{Document, Labels}
  alias Zaq.Ingestion.Labels.{Assignment, AssignmentValue, ResourceLabels}
  alias Zaq.Permissions

  describe "manual assignments" do
    property "scale values lie on the configured grid" do
      check all(
              minimum <- integer(-50..50),
              increment <- integer(2..10),
              steps <- integer(1..20),
              position <- integer(0..20),
              magnitude <- integer(0..80)
            ) do
        minimum = minimum * Integer.pow(10, magnitude)

        label = %{
          value_type: "scale",
          value_config: %{
            "min" => minimum,
            "max" => minimum + steps * increment,
            "increment" => increment
          }
        }

        value = minimum + rem(position, steps + 1) * increment
        assert AssignmentValue.valid_for?(label, value)
        refute AssignmentValue.valid_for?(label, value + 1)
      end
    end

    test "scale grid checks are exact beyond decimal context precision" do
      maximum = Integer.pow(10, 37)

      label = %{
        value_type: "scale",
        value_config: %{"min" => 0, "max" => maximum, "increment" => 2}
      }

      assert AssignmentValue.valid_for?(label, maximum)
      assert AssignmentValue.valid_for?(label, maximum - 2)
      refute AssignmentValue.valid_for?(label, maximum - 1)

      decimals = %{
        value_type: "scale",
        value_config: %{"min" => -0.3, "max" => 0.3, "increment" => 0.1}
      }

      assert AssignmentValue.valid_for?(decimals, 0.0)
      assert AssignmentValue.valid_for?(decimals, 0.3)
      refute AssignmentValue.valid_for?(decimals, 0.31)
    end

    test "typed false and zero values remain assigned; automatic nil is pending" do
      actor = %{user_id: super_admin_fixture(%{must_change_password: false}).id}
      {:ok, document} = Document.create(%{source: "typed-assignment"})
      resource = %{type: "document", id: document.id}

      for {type, config, value} <- [
            {"boolean", %{}, false},
            {"scale", %{"min" => 0, "max" => 10, "increment" => 2}, 0},
            {"options", %{"options" => [%{"id" => "stable", "label" => "Stable"}]}, "stable"}
          ] do
        {:ok, label} =
          label_definition(actor, %{
            name: type,
            value_type: type,
            value_config: config,
            resources: ["document"]
          })

        assert {:error, :invalid_value} =
                 Labels.edit_resource(
                   resource,
                   [%{label_id: label.id, operation: "add", expected_version: 0}],
                   actor
                 )

        assert {:ok, %{labels: rows}} =
                 Labels.edit_resource(
                   resource,
                   [%{label_id: label.id, operation: "add", value: value, expected_version: 0}],
                   actor
                 )

        assert %{selected: true, state: :assigned, value: ^value} =
                 Enum.find(rows, &(&1.id == label.id))
      end

      {:ok, label} =
        label_definition(actor, %{
          name: "Pending",
          value_type: "boolean",
          resources: ["document"],
          assignment_type: "automatic",
          threshold: 80
        })

      assert {:ok, %{labels: rows}} =
               Labels.edit_resource(
                 resource,
                 [%{label_id: label.id, operation: "add", expected_version: 0}],
                 actor
               )

      assert %{selected: true, state: :pending, value: nil} =
               Enum.find(rows, &(&1.id == label.id))

      assert {:ok, %{labels: rows}} =
               Labels.edit_resource(
                 resource,
                 [%{label_id: label.id, operation: "remove", expected_version: 1}],
                 actor
               )

      assert %{selected: false, state: :excluded, value: nil} =
               Enum.find(rows, &(&1.id == label.id))
    end

    test "typed bulk Actions and queries preserve native values and pending state" do
      actor = %{user_id: super_admin_fixture(%{must_change_password: false}).id}
      {:ok, document} = Document.create(%{source: "typed-query"})
      {:ok, _} = Permissions.grant_public(document)
      resource = %{type: "document", id: document.id}

      {:ok, label} =
        label_definition(actor, %{
          value_type: "boolean",
          resources: ["document"],
          assignment_type: "automatic"
        })

      assert {:ok, _} =
               Labels.edit_resource(
                 resource,
                 [%{label_id: label.id, operation: "add", expected_version: 0}],
                 actor
               )

      assert {:ok, [%{value: nil, state: :pending, documents: 1}]} =
               Labels.list_values(label.id, "", 0, actor)

      assert {:ok, chips} = Labels.document_chips([document.source], actor)
      assert [%{state: :pending, value: nil}] = chips[document.source].chips

      assert {:ok, 1} =
               label_event(
                 :update_label_values,
                 %{
                   label_id: label.id,
                   resources: [%{type: "document", id: document.id, expected_version: 1}],
                   value: false
                 },
                 actor
               )

      assert {:ok, [%{value: false, state: :assigned, documents: 1}]} =
               Labels.list_values(label.id, "false", 0, actor)

      assert {:ok, [%{value: false, expected_version: 2}]} =
               Labels.value_resources(label.id, false, 0, actor)

      assert {:ok, [false]} = Labels.value_suggestions(resource, label.id, "", actor)

      params = %{
        resource_type: "document",
        filters: %{"label_values" => [%{"label_id" => label.id, "value" => false}]},
        fields: ["id", "labels"]
      }

      assert {:ok, %{resources: [%{id: id, labels: [%{value: false, state: :assigned}]}]}} =
               label_event(:query_resources, params, actor)

      assert id == document.id

      assert {:ok, %{labels: rows}} =
               Labels.edit_resource(
                 resource,
                 [%{label_id: label.id, operation: "reset_automatic", expected_version: 2}],
                 actor
               )

      assert %{state: :pending, origin: :automatic} = Enum.find(rows, &(&1.id == label.id))
      assert {:ok, %{resources: []}} = label_event(:query_resources, params, actor)
    end

    test "option usage and suggestions search display labels without widening visibility" do
      actor = %{user_id: super_admin_fixture(%{must_change_password: false}).id}
      {:ok, document} = Document.create(%{source: "typed-option-search"})
      resource = %{type: "document", id: document.id}

      {:ok, label} =
        label_definition(actor, %{
          value_type: "options",
          resources: ["document"],
          value_config: %{"options" => [%{"id" => "opaque-1", "label" => "Paris 100%"}]}
        })

      assert {:ok, _} =
               Labels.edit_resource(
                 resource,
                 [
                   %{label_id: label.id, operation: "add", expected_version: 0, value: "opaque-1"}
                 ],
                 actor
               )

      assert {:ok, [%{value: "opaque-1", documents: 1}]} =
               Labels.list_values(label.id, "Paris 100%", 0, actor)

      assert {:ok, ["opaque-1"]} = Labels.value_suggestions(resource, label.id, "100%", actor)

      staff = %{user_id: staff_fixture(%{must_change_password: false}).id}
      assert {:ok, []} = Labels.list_values(label.id, "Paris", 0, staff)
      assert {:error, :forbidden} = Labels.value_suggestions(resource, label.id, "Paris", staff)
    end

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

      assignment = Repo.get_by!(Assignment, document_id: document.id, label_id: label.id)
      assert assignment.state == :excluded
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

      refute Repo.reload!(assignment).state == :assigned

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
        label_definition(actor, %{
          name: "Location",
          value_type: "options",
          value_config:
            option_config(
              [
                "Paris",
                "London",
                "Lyon",
                "Berlin",
                "Private city",
                "Changed",
                "Café",
                "AAA private"
              ] ++
                Enum.map(1..25, &"City #{String.pad_leading(to_string(&1), 2, "0")}")
            )
        })

      {:ok, first} = Document.create(%{source: "value-first"})
      {:ok, second} = Document.create(%{source: "value-second"})
      %{actor: actor, label: label, first: first, second: second}
    end

    test "values belong to assignments and value-only edits use optimistic versions", ctx do
      assert {:ok, _} = edit(ctx, ctx.first, "Paris", 0)
      assert {:ok, _} = edit(ctx, ctx.second, "London", 0)

      assert {:ok, %{labels: [%{value: "Paris", expected_version: 1}]}} =
               Labels.resource_editor(resource(ctx.first), ctx.actor)

      assert {:ok, chips} =
               Labels.document_chips([ctx.first.source, ctx.second.source], ctx.actor)

      assert Enum.map(chips[ctx.first.source].chips, &Map.take(&1, [:id, :name, :value, :state])) ==
               [
                 %{id: ctx.label.id, name: "Location", value: "Paris", state: :assigned}
               ]

      assert Enum.map(chips[ctx.second.source].chips, &Map.take(&1, [:id, :name, :value, :state])) ==
               [
                 %{id: ctx.label.id, name: "Location", value: "London", state: :assigned}
               ]

      assert {:ok, _} = edit(ctx, ctx.first, "Lyon", 1)
      assert {:error, :stale} = edit(ctx, ctx.first, "Berlin", 1)
      assert Repo.get_by!(Assignment, document_id: ctx.first.id).value == "Lyon"

      assert {:ok, ["London", "Lyon"]} =
               Labels.value_suggestions(resource(ctx.first), ctx.label.id, "", ctx.actor)
    end

    test "invalid values fail the batch and removal clears the old value", ctx do
      assert {:ok, _} = edit(ctx, ctx.first, "Paris", 0)

      for invalid <- [123, %{}, String.duplicate("x", 201)] do
        assert {:error, :invalid_value} = edit(ctx, ctx.first, invalid, 1)
        assert Repo.get_by!(Assignment, document_id: ctx.first.id).value == "Paris"
      end

      assert {:ok, _} =
               Labels.edit_resource(
                 resource(ctx.first),
                 [%{label_id: ctx.label.id, operation: "remove", expected_version: 1}],
                 ctx.actor
               )

      assert %{state: :excluded, value: nil} =
               Repo.get_by!(Assignment, document_id: ctx.first.id)

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

    test "option identities are exact, suggestions deduplicate and blank values are rejected",
         ctx do
      assert {:error, :invalid_value} = edit(ctx, ctx.first, " Cafe\u0301 ", 0)
      assert {:ok, _} = edit(ctx, ctx.first, "Café", 0)
      assert {:ok, _} = edit(ctx, ctx.second, "Café", 0)

      assert {:ok, ["Café"]} =
               Labels.value_suggestions(resource(ctx.first), ctx.label.id, "", ctx.actor)

      assert {:error, :invalid_value} = edit(ctx, ctx.first, "   ", 1)
      assert Repo.get_by!(Assignment, document_id: ctx.first.id).value == "Café"
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

    property "native assignment values round-trip without coercion or identity normalization" do
      check all(
              value <-
                one_of([
                  boolean(),
                  integer(),
                  string(:alphanumeric, min_length: 1, max_length: 100)
                ])
            ) do
        assert AssignmentValue.normalize(value) === value
        assert {:ok, envelope} = AssignmentValue.dump(value)
        assert AssignmentValue.load(envelope) === {:ok, value}
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
                 %{attrs: %{name: "Architecture", resources: ["document"]}},
                 actor
               )

      {:ok, document} = Document.create(%{source: "label-events"})
      resource = %{type: "document", id: document.id}

      assert {:ok, %{labels: [%{selected: true}]}} =
               label_event(
                 :edit_resource_labels,
                 %{
                   resource: resource,
                   edits: [
                     %{label_id: label.id, expected_version: 0, operation: "add", value: true}
                   ]
                 },
                 actor
               )

      assert {:ok, [%{id: id}]} = label_event(:list_labels, %{}, actor)
      assert id == label.id

      assert {:ok, %{editable?: true}} =
               label_event(:get_resource_labels, %{resource: resource}, actor)

      assert {:ok, chips} =
               label_event(:document_label_chips, %{sources: [document.source]}, actor)

      assert Enum.map(chips[document.source].chips, &Map.take(&1, [:id, :name, :value, :state])) ==
               [%{id: id, name: "Architecture", value: true, state: :assigned}]

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

      manager = %{user_id: super_admin_fixture(%{must_change_password: false}).id}
      {:ok, label} = label_definition(manager, %{resources: ["document"]})
      resource = %{type: "document", id: document.id}

      assert {:ok, _} =
               Labels.edit_resource(
                 resource,
                 [%{label_id: label.id, operation: "add", value: false, expected_version: 0}],
                 manager
               )

      edits = [%{label_id: label.id, operation: "add", value: true, expected_version: 1}]

      assert {:ok, %{result: {:error, :forbidden}}} =
               Jido.Exec.run(
                 Zaq.Ingestion.Actions.EditResourceLabels,
                 %{resource: resource, edits: edits},
                 %{actor: actor}
               )

      assert %{value: false, lock_version: 1} =
               Repo.get_by!(Assignment, document_id: document.id, label_id: label.id)

      assert {:ok, :ok} = ResourceLabels.edit(resource, edits, actor, return_projection: false)

      assert %{value: true, lock_version: 2} =
               Repo.get_by!(Assignment, document_id: document.id, label_id: label.id)
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

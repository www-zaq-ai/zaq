defmodule Zaq.Ingestion.Labels.CatalogTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  import Zaq.AccountsFixtures
  import Zaq.LabelFixtures

  alias Zaq.Ingestion.{Document, Labels}
  alias Zaq.Ingestion.Labels.{Assignment, Label}

  describe "definitions" do
    setup do
      role = role_fixture(%{name: "super_admin"})
      user = user_fixture(%{role_id: role.id, must_change_password: false})
      {:ok, document} = Document.create(%{source: "labels-#{System.unique_integer([:positive])}"})

      %{actor: %{user_id: user.id}, document: document}
    end

    test "names are unique ignoring case and surrounding whitespace", %{actor: actor} do
      assert {:ok, _} = label_definition(actor)
      assert {:error, changeset} = label_definition(actor, %{name: " security "})
      assert errors_on(changeset).name != []
    end

    test "typed definitions validate scale grids and stable option identities", %{actor: actor} do
      assert {:ok, scale} =
               label_definition(actor, %{
                 value_type: "scale",
                 value_config: %{"min" => 0, "max" => 10, "increment" => 2},
                 resources: ["document"],
                 assignment_type: "automatic",
                 threshold: 75
               })

      assert scale.value_type == "scale"
      assert scale.assignment_type == "automatic"
      assert scale.threshold == 75
      assert scale.resources == ["document"]

      for flag <- [:automatic, :automatic_document, :automatic_chunk] do
        assert {:error, :invalid_request} = label_definition(actor, %{flag => true})
      end

      for config <- [
            %{"min" => 2, "max" => 0, "increment" => 1},
            %{"min" => 0, "max" => 10, "increment" => 0},
            %{"min" => 0, "max" => 10, "increment" => 3}
          ] do
        assert {:error, changeset} =
                 label_definition(actor, %{
                   name: "Bad scale",
                   value_type: "scale",
                   value_config: config
                 })

        assert errors_on(changeset).value_config != []
      end

      assert {:error, changeset} =
               label_definition(actor, %{
                 name: "Bad options",
                 value_type: "options",
                 value_config: %{
                   "options" => [
                     %{"id" => "same", "label" => "One"},
                     %{"id" => "same", "label" => "Two"}
                   ]
                 }
               })

      assert errors_on(changeset).value_config != []

      assert {:ok, many_options} =
               label_definition(actor, %{
                 name: "Many choices",
                 value_type: "options",
                 value_config: option_config(Enum.map(1..201, &"option-#{&1}"))
               })

      assert length(many_options.value_config["options"]) == 201
    end

    test "used values prevent incompatible definition changes", %{
      actor: actor,
      document: document
    } do
      assert {:ok, label} =
               label_definition(actor, %{value_type: "boolean", resources: ["document"]})

      assert {:ok, _} =
               Labels.edit_resource(
                 %{type: "document", id: document.id},
                 [
                   %{label_id: label.id, operation: "add", value: false, expected_version: 0}
                 ],
                 actor
               )

      assert {:error, :definition_in_use} =
               Labels.save_definition(
                 %{
                   id: label.id,
                   expected_version: label.lock_version,
                   name: label.name,
                   resources: ["document"],
                   value_type: "scale",
                   value_config: %{"min" => 0, "max" => 10, "increment" => 1}
                 },
                 actor
               )

      assert Repo.get!(Label, label.id).value_type == "boolean"

      {:ok, scale} =
        label_definition(actor, %{
          name: "Used scale",
          value_type: "scale",
          value_config: %{"min" => 0, "max" => 10, "increment" => 2},
          resources: ["document"]
        })

      assert {:ok, _} =
               Labels.edit_resource(
                 %{type: "document", id: document.id},
                 [%{label_id: scale.id, operation: "add", value: 10, expected_version: 0}],
                 actor
               )

      assert {:error, :definition_in_use} =
               Labels.save_definition(
                 %{
                   id: scale.id,
                   expected_version: scale.lock_version,
                   value_config: %{"min" => 0, "max" => 8, "increment" => 2}
                 },
                 actor
               )

      assert Repo.get!(Label, scale.id).value_config["max"] == 10
    end

    test "cosmetic definition edits preserve assigned and pending decisions", %{
      actor: actor,
      document: document
    } do
      resource = %{type: "document", id: document.id}

      {:ok, label} =
        label_definition(actor, %{assignment_type: "automatic", resources: ["document"]})

      assert {:ok, _} =
               Labels.edit_resource(
                 resource,
                 [%{label_id: label.id, operation: "add", expected_version: 0}],
                 actor
               )

      assert {:ok, updated} =
               Labels.save_definition(
                 %{
                   id: label.id,
                   expected_version: label.lock_version,
                   name: "Renamed",
                   description: "New description",
                   threshold: 95,
                   resources: ["document", "chunk"]
                 },
                 actor
               )

      assert {:ok, %{labels: [%{state: :pending, expected_version: 1}]}} =
               Labels.resource_editor(resource, actor)

      assert {:error, :definition_in_use} =
               Labels.save_definition(
                 %{
                   id: label.id,
                   expected_version: updated.lock_version,
                   assignment_type: "manual"
                 },
                 actor
               )

      assert {:error, :target_in_use} =
               Labels.save_definition(
                 %{id: label.id, expected_version: updated.lock_version, resources: ["chunk"]},
                 actor
               )

      assert {:ok, _} =
               Labels.edit_resource(
                 resource,
                 [%{label_id: label.id, operation: "add", value: false, expected_version: 1}],
                 actor
               )

      assert {:ok, _} =
               Labels.save_definition(
                 %{
                   id: label.id,
                   expected_version: updated.lock_version,
                   name: "Renamed again",
                   threshold: 90
                 },
                 actor
               )

      assert {:ok, %{labels: [%{state: :assigned, value: false, expected_version: 2}]}} =
               Labels.resource_editor(resource, actor)
    end

    test "definition versions and target-in-use guards", %{actor: actor, document: document} do
      {:ok, label} = label_definition(actor)

      assert {:ok, updated} =
               Labels.save_definition(
                 %{
                   id: label.id,
                   expected_version: label.lock_version,
                   name: "Security",
                   description: "Updated",
                   resources: ["document", "chunk"]
                 },
                 actor
               )

      assert {:error, :stale} =
               Labels.save_definition(
                 %{
                   id: label.id,
                   expected_version: label.lock_version,
                   name: "Old",
                   resources: ["document"]
                 },
                 actor
               )

      assert {:ok, _} =
               Labels.edit_resource(
                 %{type: "document", id: document.id},
                 [%{label_id: label.id, operation: "remove", expected_version: 0}],
                 actor
               )

      assert {:error, :target_in_use} =
               Labels.save_definition(
                 %{
                   id: label.id,
                   expected_version: updated.lock_version,
                   name: "Security",
                   resources: ["chunk"]
                 },
                 actor
               )
    end

    test "rejects missing actors, forged bypass and deprecated per-target automatic settings", %{
      actor: actor,
      document: document
    } do
      assert {:error, :unauthorized} = label_definition(nil)
      staff = user_fixture(%{must_change_password: false})
      assert {:error, :forbidden} = label_definition(%{user_id: staff.id, skip_permissions: true})

      assert {:error, :forbidden} =
               Labels.resource_editor(%{type: "document", id: document.id}, %{
                 user_id: staff.id,
                 skip_permissions: true
               })

      assert {:error, :invalid_request} = label_definition(actor, %{automatic: true})

      assert {:ok, %{assignment_type: "automatic"}} =
               label_definition(actor, %{assignment_type: "automatic"})
    end

    property "normalization treats name case and surrounding whitespace equivalently" do
      check all(name <- string(:alphanumeric, min_length: 1, max_length: 60)) do
        original =
          Label.changeset(%Label{}, %{name: name})

        variant =
          Label.changeset(%Label{}, %{
            name: "  #{String.upcase(name)}  "
          })

        assert Ecto.Changeset.get_field(original, :normalized_name) ==
                 Ecto.Changeset.get_field(variant, :normalized_name)
      end
    end
  end

  describe "deletion" do
    setup do
      user = super_admin_fixture(%{must_change_password: false})
      actor = %{user_id: user.id}

      {:ok, label} =
        Labels.save_definition(%{name: "Delete me", resources: ["document", "chunk"]}, actor)

      {:ok, document} = Document.create(%{source: "delete-label-test"})
      %{actor: actor, label: label, document: document}
    end

    test "bulk deletion rolls back earlier deletes when later usage changes", ctx do
      {:ok, other} = Labels.save_definition(%{name: "Second", resources: ["document"]}, ctx.actor)

      assert {:ok, previews} =
               label_event(:labels_deletion_preview, %{ids: [other.id, ctx.label.id]}, ctx.actor)

      assert {:ok, _} =
               Labels.edit_resource(
                 %{type: "document", id: ctx.document.id},
                 [%{label_id: other.id, operation: "add", value: true, expected_version: 0}],
                 ctx.actor
               )

      requests = Enum.map(previews, &request/1)

      assert {:error, {:usage_changed, _}} =
               label_event(:delete_label_definitions, %{labels: requests}, ctx.actor)

      assert Repo.get(Label, ctx.label.id)
      assert Repo.get(Label, other.id)
      assert {:ok, fresh} = Labels.bulk_deletion_preview([ctx.label.id, other.id], ctx.actor)

      assert {:ok, [_, _]} =
               label_event(
                 :delete_label_definitions,
                 %{labels: Enum.map(fresh, &request/1)},
                 ctx.actor
               )

      refute Repo.get(Label, ctx.label.id)
      refute Repo.get(Label, other.id)
      assert Repo.get(Document, ctx.document.id)
    end

    test "bulk endpoints reject unauthorized and malformed batches", ctx do
      assert {:error, _} = Labels.bulk_deletion_preview([ctx.label.id], nil)
      assert {:error, _} = Labels.delete_definitions([], nil)

      for ids <- [[], [ctx.label.id, ctx.label.id], [0], Enum.to_list(1..51)] do
        assert {:error, :invalid_request} = Labels.bulk_deletion_preview(ids, ctx.actor)
      end

      assert {:error, :invalid_request} = Labels.delete_definitions([%{}], ctx.actor)
      assert {:error, :invalid_request} = Labels.delete_definitions(nil, ctx.actor)
    end

    test "unused deletion uses validated Event and removes its definition", ctx do
      assert {:ok, preview} = label_event(:label_deletion_preview, %{id: ctx.label.id}, ctx.actor)
      assert preview.usage == %{documents: 0, chunks: 0}
      assert {:ok, %{id: id}} = label_event(:delete_label_definition, request(preview), ctx.actor)
      assert id == ctx.label.id
      refute Repo.get(Label, id)
      refute Repo.get_by(Assignment, label_id: id)
      assert Repo.get(Document, ctx.document.id)
      assert {:error, :not_found} = Labels.deletion_preview(id, ctx.actor)
      assert {:error, _} = label_event(:delete_label_definition, %{id: id}, ctx.actor)
    end

    test "selected usage requires refreshed confirmation and deletes assignments, not documents",
         ctx do
      {:ok, preview} = Labels.deletion_preview(ctx.label.id, ctx.actor)
      assign_label(ctx, "add")

      assert {:error, {:usage_changed, updated}} =
               Labels.delete_definition(request(preview), ctx.actor)

      assert updated.usage == %{documents: 1, chunks: 0}
      assert Repo.get(Label, ctx.label.id)
      assert {:ok, _} = Labels.delete_definition(request(updated), ctx.actor)
      refute Repo.get_by(Assignment, label_id: ctx.label.id)
      assert Repo.get(Document, ctx.document.id)
    end

    test "manual exclusions are cleaned without reporting them as selected usage", ctx do
      assign_label(ctx, "remove")
      {:ok, preview} = Labels.deletion_preview(ctx.label.id, ctx.actor)
      assert preview.usage.documents == 0
      assert {:ok, _} = Labels.delete_definition(request(preview), ctx.actor)
      refute Repo.get_by(Assignment, label_id: ctx.label.id)
    end

    test "definition revisions, manager authorization and malformed confirmations are enforced",
         ctx do
      {:ok, preview} = Labels.deletion_preview(ctx.label.id, ctx.actor)

      {:ok, _} =
        Labels.save_definition(
          %{
            id: ctx.label.id,
            expected_version: ctx.label.lock_version,
            name: "Renamed",
            resources: ["document", "chunk"]
          },
          ctx.actor
        )

      assert {:error, :stale} = Labels.delete_definition(request(preview), ctx.actor)
      staff = staff_fixture(%{must_change_password: false})
      assert {:error, :forbidden} = Labels.deletion_preview(ctx.label.id, %{user_id: staff.id})

      assert {:error, :forbidden} =
               Labels.delete_definition(request(preview), %{
                 user_id: staff.id,
                 skip_permissions: true
               })

      assert {:error, :unauthorized} = Labels.delete_definition(request(preview), nil)
      assert {:error, :invalid_request} = Labels.delete_definition(%{id: ctx.label.id}, ctx.actor)
      assert Repo.get(Label, ctx.label.id)
    end
  end

  describe "catalog events" do
    test "catalog search preserves literal query characters and rejects invalid input" do
      user = super_admin_fixture(%{must_change_password: false})
      actor = %{user_id: user.id}

      {:ok, label} =
        Labels.save_definition(
          %{name: "Coverage 100%", description: "a_b", resources: ["document"]},
          actor
        )

      {:ok, _} = Labels.save_definition(%{name: "Other", resources: ["document"]}, actor)
      assert {:ok, [found]} = label_event(:list_labels, %{query: "%"}, actor)
      assert found.id == label.id
      assert {:ok, [_]} = label_event(:list_labels, %{query: "_"}, actor)
      assert {:error, :invalid_request} = label_event(:list_labels, %{query: []}, actor)
      assert {:error, :unauthorized} = label_event(:list_labels, %{query: "%"}, nil)
    end
  end

  defp assign_label(ctx, operation) do
    {:ok, _} =
      Labels.edit_resource(
        %{type: "document", id: ctx.document.id},
        [%{label_id: ctx.label.id, operation: operation, value: true, expected_version: 0}],
        ctx.actor
      )
  end

  defp request(preview),
    do: %{
      id: preview.id,
      expected_version: preview.expected_version,
      expected_usage: preview.usage
    }
end

defmodule Zaq.Ingestion.Labels.CatalogTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  import Zaq.AccountsFixtures
  import Zaq.LabelFixtures

  alias Zaq.Ingestion.{Document, Labels}
  alias Zaq.Ingestion.Labels.{DocumentAssignment, Label, Target}

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

    test "definition versions and target-in-use guards", %{actor: actor, document: document} do
      {:ok, label} = label_definition(actor)

      assert {:ok, updated} =
               Labels.save_definition(
                 %{
                   id: label.id,
                   expected_version: label.lock_version,
                   name: "Security",
                   description: "Updated",
                   targets: ["document", "chunk"]
                 },
                 actor
               )

      assert {:error, :stale} =
               Labels.save_definition(
                 %{
                   id: label.id,
                   expected_version: label.lock_version,
                   name: "Old",
                   targets: ["document"]
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
                   targets: ["chunk"]
                 },
                 actor
               )
    end

    test "rejects missing actors and forged bypass and automatic settings", %{
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

      assert {:error, :automation_unavailable} = label_definition(actor, %{automatic: true})
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
        Labels.save_definition(%{name: "Delete me", targets: ["document", "chunk"]}, actor)

      {:ok, document} = Document.create(%{source: "delete-label-test"})
      %{actor: actor, label: label, document: document}
    end

    test "bulk deletion rolls back earlier deletes when later usage changes", ctx do
      {:ok, other} = Labels.save_definition(%{name: "Second", targets: ["document"]}, ctx.actor)

      assert {:ok, previews} =
               label_event(:labels_deletion_preview, %{ids: [other.id, ctx.label.id]}, ctx.actor)

      assert {:ok, _} =
               Labels.edit_resource(
                 %{type: "document", id: ctx.document.id},
                 [%{label_id: other.id, operation: "add", expected_version: 0}],
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

    test "unused deletion uses validated Event and removes targets", ctx do
      assert {:ok, preview} = label_event(:label_deletion_preview, %{id: ctx.label.id}, ctx.actor)
      assert preview.usage == %{documents: 0, chunks: 0}
      assert {:ok, %{id: id}} = label_event(:delete_label_definition, request(preview), ctx.actor)
      assert id == ctx.label.id
      refute Repo.get(Label, id)
      refute Repo.get_by(Target, label_id: id)
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
      refute Repo.get_by(DocumentAssignment, label_id: ctx.label.id)
      assert Repo.get(Document, ctx.document.id)
    end

    test "manual exclusions are cleaned without reporting them as selected usage", ctx do
      assign_label(ctx, "remove")
      {:ok, preview} = Labels.deletion_preview(ctx.label.id, ctx.actor)
      assert preview.usage.documents == 0
      assert {:ok, _} = Labels.delete_definition(request(preview), ctx.actor)
      refute Repo.get_by(DocumentAssignment, label_id: ctx.label.id)
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
            targets: ["document", "chunk"]
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
          %{name: "Coverage 100%", description: "a_b", targets: ["document"]},
          actor
        )

      {:ok, _} = Labels.save_definition(%{name: "Other", targets: ["document"]}, actor)
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
        [%{label_id: ctx.label.id, operation: operation, expected_version: 0}],
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

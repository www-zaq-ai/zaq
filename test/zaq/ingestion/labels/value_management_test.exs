defmodule Zaq.Ingestion.Labels.ValueManagementTest do
  # The chunk usage test creates its dynamic table inside the SQL Sandbox.
  use Zaq.DataCase, async: false
  use ExUnitProperties
  import Zaq.AccountsFixtures
  import Zaq.LabelFixtures
  alias Zaq.Accounts.People
  alias Zaq.Ingestion.{Chunk, Document, Labels}
  alias Zaq.Ingestion.Labels.{Assignment, ValueManagement}
  alias Zaq.Permissions

  setup do
    user = super_admin_fixture(%{must_change_password: false})
    actor = %{user_id: user.id}

    {:ok, label} =
      label_definition(actor, %{
        name: "Location",
        value_type: "options",
        value_config:
          option_config(
            ["Paris", "London", "Berlin", "Rome", "Tokyo", "Unspecified", "X"] ++
              Enum.map(1..52, &"City #{&1}%")
          )
      })

    docs = for n <- 1..3, do: elem(Document.create(%{source: "usage-#{n}"}), 1)

    for {doc, value} <- Enum.zip(docs, ["Paris", "Paris", "Unspecified"]) do
      {:ok, _} =
        Labels.edit_resource(
          %{type: "document", id: doc.id},
          [%{label_id: label.id, expected_version: 0, operation: "add", value: value}],
          actor
        )
    end

    %{actor: actor, label: label, docs: docs}
  end

  test "usage groups explicit options and chunks; resource identities stay typed",
       ctx do
    assert :ok = Chunk.create_table(1536)
    doc = hd(ctx.docs)
    chunk = Repo.insert!(%Chunk{document_id: doc.id, content: "Paris", chunk_index: 0})

    {:ok, _} =
      Labels.edit_resource(
        %{type: "chunk", id: chunk.id},
        [%{label_id: ctx.label.id, expected_version: 0, operation: "add", value: "Paris"}],
        ctx.actor
      )

    assert {:ok, rows} = ValueManagement.values(ctx.label.id, "", 0, ctx.actor)

    assert Enum.find(rows, &(&1.value == "Unspecified")) == %{
             value: "Unspecified",
             state: :assigned,
             documents: 1,
             chunks: 0
           }

    assert Enum.find(rows, &(&1.value == "Paris")) == %{
             value: "Paris",
             state: :assigned,
             documents: 2,
             chunks: 1
           }

    assert {:ok, summaries} = ValueManagement.summaries([ctx.label.id], ctx.actor)
    assert summaries[ctx.label.id] == %{values: 2, resources: 4}
    assert {:ok, resources} = ValueManagement.resources(ctx.label.id, "Paris", 0, ctx.actor)
    assert Enum.count(resources, &(&1.type == "document")) == 2
    assert Enum.count(resources, &(&1.type == "chunk")) == 1
    assert Enum.all?(resources, &(&1.editable? and &1.expected_version == 1))
    assert {:ok, [_]} = ValueManagement.resources(ctx.label.id, "Unspecified", 0, ctx.actor)
  end

  test "validated bulk action changes only selected resources and requires an explicit option",
       ctx do
    {:ok, [first | _]} = ValueManagement.resources(ctx.label.id, "Paris", 0, ctx.actor)
    assert {:ok, 1} = apply_value(ctx, [first], "London")
    assert Repo.get_by!(Assignment, document_id: first.id).value == "London"
    assert {:ok, [_]} = ValueManagement.resources(ctx.label.id, "Paris", 0, ctx.actor)
    {:ok, [updated]} = ValueManagement.resources(ctx.label.id, "London", 0, ctx.actor)
    assert {:error, :invalid_value} = apply_value(ctx, [updated], "")
    assert {:ok, 1} = apply_value(ctx, [updated], "Unspecified")
    assignment = Repo.get_by!(Assignment, document_id: first.id)
    assert assignment.state == :assigned
    assert assignment.value == "Unspecified"
    assert {:ok, []} = ValueManagement.values(ctx.label.id, "London", 0, ctx.actor)
  end

  test "stale selection rolls back the entire batch", ctx do
    {:ok, [first, second]} = ValueManagement.resources(ctx.label.id, "Paris", 0, ctx.actor)
    assert {:ok, 1} = apply_value(ctx, [second], "Berlin")
    assert {:error, :stale} = apply_value(ctx, [first, second], "Rome")
    assert Repo.get_by!(Assignment, document_id: first.id).value == "Paris"
    assert Repo.get_by!(Assignment, document_id: second.id).value == "Berlin"
  end

  test "discovery respects read rights and bulk writes require read and update rights", ctx do
    user = staff_fixture(%{must_change_password: false})
    {:ok, person} = People.create_person(%{full_name: "Value reader"})
    actor = %{user_id: user.id, person_id: person.id, skip_permissions: true}
    doc = hd(ctx.docs)
    assert {:ok, []} = ValueManagement.values(ctx.label.id, "", 0, actor)
    assert {:ok, %{}} = ValueManagement.summaries([ctx.label.id], %{user_id: user.id})
    {:ok, _} = Permissions.grant(doc, %{person_id: person.id, access_rights: ["read"]})

    assert {:ok, [%{documents: 1, value: "Paris"}]} =
             ValueManagement.values(ctx.label.id, "", 0, actor)

    assert {:ok, [row]} = ValueManagement.resources(ctx.label.id, "Paris", 0, actor)
    refute row.editable?
    assert {:error, :forbidden} = apply_value(%{ctx | actor: actor}, [row], "Rome")
    assert {:error, :unauthorized} = ValueManagement.values(ctx.label.id, "", 0, nil)
    {:ok, _} = Permissions.grant(doc, %{person_id: person.id, access_rights: ["read", "update"]})
    assert {:ok, 1} = apply_value(%{ctx | actor: actor}, [row], "Rome")
  end

  test "invalid bulk inputs cannot create assignments or mutate anything", ctx do
    {:ok, [first | _]} = ValueManagement.resources(ctx.label.id, "Paris", 0, ctx.actor)
    assert {:error, :invalid_request} = ValueManagement.update(ctx.label.id, [], "X", ctx.actor)

    assert {:error, :invalid_request} =
             ValueManagement.update(ctx.label.id, [first, first], "X", ctx.actor)

    assert {:error, :invalid_value} =
             ValueManagement.update(ctx.label.id, [first], String.duplicate("x", 201), ctx.actor)

    assert {:error, :invalid_request} =
             ValueManagement.update(
               ctx.label.id,
               [%{first | expected_version: 0}],
               "X",
               ctx.actor
             )

    assert {:error, :invalid_request} = ValueManagement.resources(ctx.label.id, [], 0, ctx.actor)
  end

  test "revoked access rolls back other selected resources and update-only grants do not expose values",
       ctx do
    user = staff_fixture(%{must_change_password: false})
    {:ok, person} = People.create_person(%{full_name: "Former editor"})
    actor = %{user_id: user.id, person_id: person.id}
    [first, second | _] = ctx.docs

    {:ok, _} =
      Permissions.grant(first, %{person_id: person.id, access_rights: ["read", "update"]})

    {:ok, grant} =
      Permissions.grant(second, %{person_id: person.id, access_rights: ["read", "update"]})

    assert {:ok, rows} = ValueManagement.resources(ctx.label.id, "Paris", 0, actor)
    assert length(rows) == 2
    assert :ok = Permissions.revoke(second, grant)
    {:ok, _} = Permissions.grant(second, %{person_id: person.id, access_rights: ["update"]})
    assert {:ok, [%{documents: 1}]} = ValueManagement.values(ctx.label.id, "", 0, actor)
    assert {:error, :forbidden} = apply_value(%{ctx | actor: actor}, rows, "Rome")
    assert Repo.get_by!(Assignment, document_id: first.id).value == "Paris"
    assert Repo.get_by!(Assignment, document_id: second.id).value == "Paris"
  end

  test "removed assignments cannot be revived by a bulk value correction", ctx do
    doc = hd(ctx.docs)

    {:ok, _} =
      Labels.edit_resource(
        %{type: "document", id: doc.id},
        [%{label_id: ctx.label.id, operation: "remove", expected_version: 1}],
        ctx.actor
      )

    row = %{type: "document", id: doc.id, expected_version: 2}
    assert {:error, :stale} = apply_value(ctx, [row], "Paris")
    refute Repo.get_by!(Assignment, document_id: doc.id).state == :assigned
  end

  test "value pages are bounded and literal searches do not interpret wildcard characters", ctx do
    for n <- 1..52 do
      {:ok, doc} = Document.create(%{source: "paged-values-#{n}"})

      Repo.insert!(%Assignment{
        resource_type: "document",
        resource_id: to_string(doc.id),
        label_id: ctx.label.id,
        state: :assigned,
        origin: :manual,
        value: "City #{n}%"
      })
    end

    assert {:ok, first} = ValueManagement.values(ctx.label.id, "%", 0, ctx.actor)
    assert length(first) == 51
    assert {:ok, last} = ValueManagement.values(ctx.label.id, "%", 50, ctx.actor)
    assert length(last) == 2

    assert MapSet.disjoint?(
             MapSet.new(Enum.take(first, 50), & &1.value),
             MapSet.new(last, & &1.value)
           )

    assert {:error, :invalid_request} = ValueManagement.values(ctx.label.id, "", -1, ctx.actor)
  end

  property "bulk changes preserve every unselected assignment", ctx do
    check all(
            indexes <-
              map(list_of(integer(0..2), min_length: 1, max_length: 3), &Enum.uniq/1),
            value <- member_of(["Unspecified", "Paris", "Tokyo", "London"]),
            max_runs: 12
          ) do
      before =
        Map.new(ctx.docs, fn doc ->
          {doc.id, Repo.get_by!(Assignment, document_id: doc.id)}
        end)

      resources =
        Enum.map(indexes, fn index ->
          doc = Enum.at(ctx.docs, index)
          %{type: "document", id: doc.id, expected_version: before[doc.id].lock_version}
        end)

      assert {:ok, count} = apply_value(ctx, resources, value)
      assert count == length(resources)
      selected = MapSet.new(resources, & &1.id)

      for doc <- ctx.docs do
        after_assignment = Repo.get_by!(Assignment, document_id: doc.id)
        assert after_assignment.state == :assigned

        if MapSet.member?(selected, doc.id) do
          assert after_assignment.value == value
        else
          assert after_assignment == before[doc.id]
        end
      end
    end
  end

  defp apply_value(ctx, resources, value) do
    label_event(
      :update_label_values,
      %{label_id: ctx.label.id, resources: resources, value: value},
      ctx.actor
    )
  end
end

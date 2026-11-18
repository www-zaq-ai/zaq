defmodule Zaq.Agent.Tools.Resources.LabelQueriesTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  import Zaq.AccountsFixtures
  import Zaq.LabelFixtures

  alias Zaq.Accounts.People
  alias Zaq.Agent.Tools.Resources.QueryResources
  alias Zaq.Ingestion.{Api, Document, Labels}
  alias Zaq.Ingestion.Labels.Assignment
  alias Zaq.Permissions

  setup :verify_on_exit!

  setup do
    user = super_admin_fixture(%{must_change_password: false})
    actor = %{user_id: user.id}
    {:ok, person} = People.create_person(%{full_name: "Label reader"})
    labels = for name <- ["Security", "Architecture", "Unused"], do: label(actor, name)
    [security, architecture, unused] = labels
    both = document("A", actor, [{security, true}, {architecture, true}])
    security_only = document("B", actor, [{security, true}])
    removed = document("C", actor, [{security, false}, {architecture, true}])
    private = document("D", actor, [{unused, true}, {security, true}])
    update_only = document("E", actor, [{unused, true}, {security, true}])

    for doc <- [both, security_only, removed] do
      {:ok, _} = Permissions.grant(doc, %{person_id: person.id, access_rights: ["read"]})
    end

    {:ok, _} = Permissions.grant(update_only, %{person_id: person.id, access_rights: ["update"]})

    %{
      actor: actor,
      person: person,
      context: %{actor: %{person: %{id: person.id}}},
      security: security,
      architecture: architecture,
      unused: unused,
      both: both,
      security_only: security_only,
      removed: removed,
      private: private,
      update_only: update_only
    }
  end

  test "document get/list expose selected assignment values after authorization", ctx do
    set_value(ctx, ctx.both, ctx.security, "Paris")
    set_value(ctx, ctx.private, ctx.security, "Secret")
    assert {:ok, result} = query("document", %{id: ctx.both.id, fields: ["labels"]}, ctx.context)

    assert Enum.map(result.resource.labels, &Map.take(&1, [:id, :name, :value, :state])) == [
             %{
               id: ctx.architecture.id,
               name: "Architecture",
               value: "Unspecified",
               state: :assigned
             },
             %{id: ctx.security.id, name: "Security", value: "Paris", state: :assigned}
           ]

    assert {:ok, result} = query("document", %{fields: ["id", "labels"]}, ctx.context)

    assert Enum.find(result.resources, &(&1.id == ctx.both.id)).labels
           |> Enum.any?(&(&1.value == "Paris"))

    refute Enum.any?(result.resources, &(&1.id in [ctx.private.id, ctx.update_only.id]))
    removed = Enum.find(result.resources, &(&1.id == ctx.removed.id))
    refute Enum.any?(removed.labels, &(&1.id == ctx.security.id))

    assert {:error, :unauthorized} =
             query("document", %{id: ctx.private.id, fields: ["labels"]}, ctx.context)

    assert {:ok, %{resource: %{labels: labels}}} =
             query("document", %{id: ctx.private.id, fields: ["labels"]}, %{
               skip_permissions: true
             })

    assert Enum.any?(labels, &(&1.value == "Secret"))
  end

  test "value filters bind values to the correct label and apply any/all before pagination",
       ctx do
    set_value(ctx, ctx.both, ctx.security, "Paris")
    set_value(ctx, ctx.both, ctx.architecture, "Finance")
    set_value(ctx, ctx.security_only, ctx.security, "London")
    set_value(ctx, ctx.removed, ctx.architecture, "Paris")
    set_value(ctx, ctx.private, ctx.security, "Paris")

    pairs = [
      %{"label_id" => ctx.security.id, "value" => "Paris"},
      %{"label_id" => ctx.architecture.id, "value" => "Paris"}
    ]

    assert {:ok, any} =
             query(
               "document",
               %{filters: %{"label_values" => pairs}, limit: 1, offset: 1},
               ctx.context
             )

    assert ids(any) == [ctx.removed.id]
    assert any.total_count == 2

    assert {:ok, %{total_count: 0}} =
             query(
               "document",
               %{filters: %{"label_values" => pairs, "label_match" => "all"}},
               ctx.context
             )

    all_pairs = [hd(pairs), %{"label_id" => ctx.architecture.id, "value" => "Finance"}]

    assert {:ok, all} =
             query(
               "document",
               %{filters: %{"label_values" => all_pairs, "label_match" => "all"}},
               ctx.context
             )

    assert ids(all) == [ctx.both.id]

    assert {:ok, %{found: false}} =
             query(
               "document",
               %{id: ctx.security_only.id, filters: %{"label_values" => [hd(pairs)]}},
               ctx.context
             )

    assert {:ok, %{total_count: 0}} =
             query(
               "document",
               %{filters: %{"label_values" => [], "label_match" => "all"}},
               ctx.context
             )
  end

  test "all value filters deduplicate JSON-equivalent numeric representations", ctx do
    huge = Integer.pow(10, 100)

    for {index, value, variants} <- [
          {0, 0, [0, -0.0, 0.0]},
          {1, 1, [1, 1.0]},
          {2, -10, [-10, -10.0]},
          {3, huge, [huge, 1.0e100]},
          {4, 9_007_199_254_740_992, [9_007_199_254_740_992, 9_007_199_254_740_992.0]}
        ] do
      {:ok, label} =
        label_definition(ctx.actor, %{
          name: "Numeric equality #{index}",
          resources: ["document"],
          value_type: "scale",
          value_config: %{"min" => -huge, "max" => huge, "increment" => 1}
        })

      assert {:ok, _} =
               Labels.edit_resource(
                 %{type: "document", id: ctx.both.id},
                 [
                   %{label_id: label.id, operation: "add", value: value, expected_version: 0}
                 ],
                 ctx.actor
               )

      for variant <- variants do
        assert %{rows: [[true]]} =
                 Repo.query!("SELECT $1::text::jsonb = $2::text::jsonb", [
                   Jason.encode!(value),
                   Jason.encode!(variant)
                 ])
      end

      filters = %{
        "label_values" => Enum.map(variants, &%{"label_id" => label.id, "value" => &1}),
        "label_match" => "all"
      }

      assert :ok = Document.validate_label_filters(filters)

      assert Enum.map(Repo.all(Document.filter_by_labels(Document, filters)), & &1.id) == [
               ctx.both.id
             ]

      assert {:ok, result} =
               Jido.Exec.run(
                 QueryResources,
                 %{
                   mode: "query",
                   resource_type: "document",
                   filters: filters,
                   fields: ["id", "labels"]
                 },
                 ctx.context
               )

      assert ids(result) == [ctx.both.id]

      assert Enum.find(result.resources |> hd() |> Map.fetch!(:labels), &(&1.id == label.id)).value ===
               value
    end
  end

  property "numeric equality filters keep distinct values distinct at any Decimal precision",
           ctx do
    large = Integer.pow(10, 100)

    {:ok, label} =
      label_definition(ctx.actor, %{
        name: "Numeric distinction",
        resources: ["document"],
        value_type: "scale",
        value_config: %{"min" => -large, "max" => large, "increment" => 1}
      })

    assert {:ok, _} =
             Labels.edit_resource(
               %{type: "document", id: ctx.both.id},
               [
                 %{label_id: label.id, operation: "add", value: 0, expected_version: 0}
               ],
               ctx.actor
             )

    check all(
            value <-
              one_of([
                integer(-10_000..10_000),
                member_of([large, large - 1, -large, -large + 1])
              ]),
            max_runs: 16
          ) do
      assignment = Repo.get_by!(Assignment, document_id: ctx.both.id, label_id: label.id)

      assert {:ok, _} =
               Labels.edit_resource(
                 %{type: "document", id: ctx.both.id},
                 [
                   %{
                     label_id: label.id,
                     operation: "add",
                     value: value,
                     expected_version: assignment.lock_version
                   }
                 ],
                 ctx.actor
               )

      distinct = if value == large, do: value - 1, else: value + 1

      filters = %{
        "label_values" => [
          %{"label_id" => label.id, "value" => value},
          %{"label_id" => label.id, "value" => distinct}
        ],
        "label_match" => "all"
      }

      Decimal.Context.with(%Decimal.Context{precision: 1}, fn ->
        assert {:ok, result} = query("document", %{filters: filters}, ctx.context)
        assert result.resources == []
      end)
    end
  end

  test "native Boolean, numeric and option values retain separate identities and payloads", ctx do
    {:ok, boolean} =
      label_definition(ctx.actor, %{name: "Boolean identity", resources: ["document"]})

    {:ok, option} =
      label_definition(ctx.actor, %{
        name: "Option identity",
        resources: ["document"],
        value_type: "options",
        value_config: option_config(["0", "false", "é", "é"])
      })

    assert {:ok, _} =
             Labels.edit_resource(
               %{type: "document", id: ctx.both.id},
               [
                 %{label_id: boolean.id, operation: "add", value: false, expected_version: 0},
                 %{label_id: option.id, operation: "add", value: "0", expected_version: 0}
               ],
               ctx.actor
             )

    for {label, variants} <- [{boolean, [false, 0]}, {option, ["0", 0]}] do
      filters = %{
        "label_values" => Enum.map(variants, &%{"label_id" => label.id, "value" => &1}),
        "label_match" => "all"
      }

      assert {:ok, result} = query("document", %{filters: filters}, ctx.context)
      assert result.resources == []
    end

    assert {:ok, result} = query("document", %{id: ctx.both.id, fields: ["labels"]}, ctx.context)
    assert Enum.find(result.resource.labels, &(&1.id == boolean.id)).value === false
    assert Enum.find(result.resource.labels, &(&1.id == option.id)).value === "0"
  end

  test "value filters validate inputs and support explicit options and combined ID filters",
       ctx do
    for invalid <- [
          "Paris",
          [%{"label_id" => ctx.security.id}],
          [%{"label_id" => ctx.security.id, "value" => %{}}],
          [%{"label_id" => 0, "value" => "Paris"}],
          [%{"label_id" => ctx.security.id, "value" => String.duplicate("x", 201)}]
        ] do
      assert {:error, {:invalid_filter, "label_values"}} =
               query("document", %{filters: %{"label_values" => invalid}}, ctx.context)
    end

    filters = %{
      "label_values" => [%{"label_id" => ctx.security.id, "value" => "Unspecified"}],
      "label_ids" => [ctx.architecture.id]
    }

    assert {:ok, result} = query("document", %{filters: filters}, ctx.context)
    assert ids(result) == [ctx.both.id]

    assert {:ok, result} =
             Jido.Exec.run(
               QueryResources,
               %{resource_type: "document", filters: filters, fields: ["labels"]},
               ctx.context
             )

    assert result.count == 1
  end

  property "unknown value strings never broaden an authorized document query", ctx do
    check all(value <- string(:alphanumeric, min_length: 1, max_length: 60)) do
      filters = %{
        "label_values" => [%{"label_id" => ctx.security.id, "value" => "unknown-" <> value}]
      }

      assert {:ok, %{resources: [], total_count: 0}} =
               query("document", %{filters: filters}, ctx.context)
    end
  end

  defp set_value(ctx, doc, label, value) do
    assert {:ok, _} =
             Labels.edit_resource(
               %{type: "document", id: doc.id},
               [%{label_id: label.id, operation: "add", expected_version: 1, value: value}],
               ctx.actor
             )
  end

  test "validated Action exposes new descriptors and metadata-only document fields", ctx do
    assert {:ok, result} =
             Jido.Exec.run(QueryResources, %{mode: "describe", resource_type: "document"}, %{})

    assert [%{public: false, filter_fields: filters, fields: fields}] = result.descriptions
    assert "label_ids" in filters
    assert "label_match" in filters
    refute "content" in fields
    refute "metadata" in fields

    assert {:ok, result} =
             Jido.Exec.run(
               QueryResources,
               %{
                 resource_type: "document",
                 filters: %{"label_ids" => [ctx.security.id]}
               },
               ctx.context
             )

    assert ids(result) == [ctx.both.id, ctx.security_only.id]
    assert result.total_count == 2
    refute Enum.any?(result.resources, &Map.has_key?(&1, :content))

    assert {:error, {:unsupported_field, ["content"]}} =
             query("document", %{fields: ["content"]}, ctx.context)
  end

  test "any/all use selected assignments, exclude private documents and count before paging",
       ctx do
    filters = %{"label_ids" => [ctx.security.id, ctx.architecture.id]}
    assert {:ok, any} = query("document", %{filters: filters}, ctx.context)
    assert ids(any) == [ctx.both.id, ctx.security_only.id, ctx.removed.id]
    assert any.total_count == 3

    assert {:ok, all} =
             query("document", %{filters: Map.put(filters, "label_match", "all")}, ctx.context)

    assert ids(all) == [ctx.both.id]

    assert {:ok, page} = query("document", %{filters: filters, limit: 1, offset: 1}, ctx.context)
    assert ids(page) == [ctx.security_only.id]
    assert page.count == 1
    assert page.total_count == 3
  end

  test "label discovery inherits document visibility, searches descriptions and exposes targets",
       ctx do
    assert {:ok, result} = query("label", %{}, ctx.context)
    assert Enum.map(result.resources, & &1.name) == ["Architecture", "Security"]

    assert Enum.all?(
             result.resources,
             &(&1.resources == ["document", "chunk"] and &1.resource_types == &1.resources)
           )

    assert {:ok, searched} =
             query("label", %{query: "ABOUT SECURITY", fields: ["id", "name"]}, ctx.context)

    assert searched.resources == [%{id: ctx.security.id, name: "Security"}]
    assert {:ok, %{resources: [], total_count: 0}} = query("label", %{}, %{})
    assert {:error, :unauthorized} = query("label", %{id: ctx.unused.id}, ctx.context)
    assert {:ok, admin} = query("label", %{}, %{skip_permissions: true})
    assert length(admin.resources) == 3

    assert {:ok, %{resource: %{name: "Unused"}}} =
             query("label", %{id: ctx.unused.id}, %{skip_permissions: true})
  end

  test "Everyone and team read grants work without implicit nil-identity access", ctx do
    {:ok, _} = Permissions.grant_public(ctx.both)
    {:ok, everyone_docs} = query("document", %{}, %{})
    assert ids(everyone_docs) == [ctx.both.id]
    assert {:ok, everyone_labels} = query("label", %{}, %{})
    assert Enum.map(everyone_labels.resources, & &1.name) == ["Architecture", "Security"]

    {:ok, team} = People.create_team(%{name: "Label readers"})
    {:ok, _} = Permissions.grant(ctx.private, %{team_id: team.id, access_rights: ["read"]})
    assert {:ok, team_docs} = query("document", %{}, %{team_ids: [team.id]})
    assert ids(team_docs) == [ctx.both.id, ctx.private.id]
    assert {:ok, team_labels} = query("label", %{}, %{team_ids: [team.id]})
    assert Enum.any?(team_labels.resources, &(&1.id == ctx.unused.id))
  end

  test "get respects document permissions and label/search constraints", ctx do
    assert {:error, :unauthorized} = query("document", %{id: ctx.private.id}, ctx.context)
    assert {:error, :unauthorized} = query("document", %{id: ctx.update_only.id}, ctx.context)

    assert {:ok, %{found: false, resource: nil}} =
             query(
               "document",
               %{
                 id: ctx.security_only.id,
                 filters: %{"label_ids" => [ctx.architecture.id]}
               },
               ctx.context
             )

    assert {:ok, %{found: false}} =
             query("document", %{id: ctx.both.id, query: "missing"}, ctx.context)

    assert {:ok, %{resource: %{id: id}, found: true}} =
             query(
               "document",
               %{
                 id: ctx.both.id,
                 fields: ["id"],
                 filters: %{"label_ids" => [ctx.security.id]}
               },
               ctx.context
             )

    assert id == ctx.both.id

    assert {:ok, %{found: true}} =
             query("document", %{id: ctx.private.id}, %{skip_permissions: true})
  end

  test "empty and unknown label IDs cannot broaden results; invalid inputs return errors", ctx do
    for match <- ["any", "all"], ids <- [[], [9_223_372_036_854_775_807]] do
      assert {:ok, %{resources: [], total_count: 0}} =
               query(
                 "document",
                 %{
                   filters: %{"label_ids" => ids, "label_match" => match}
                 },
                 ctx.context
               )
    end

    for ids <- [
          nil,
          "1",
          ["1"],
          [0],
          [-1],
          [1.5],
          [nil],
          [9_223_372_036_854_775_808],
          Enum.to_list(1..101)
        ] do
      assert {:error, {:invalid_filter, "label_ids"}} =
               query("document", %{filters: %{"label_ids" => ids}}, ctx.context)
    end

    for filters <- [
          %{"label_match" => "all"},
          %{"label_ids" => [1], "label_match" => "bogus"},
          %{"label_ids" => [1], "label_match" => nil}
        ] do
      assert {:error, {:invalid_filter, "label_match"}} =
               query("document", %{filters: filters}, ctx.context)
    end
  end

  test "document sorting has a stable ID tie-breaker and combines ordinary filters", ctx do
    Repo.update_all(
      Ecto.Query.from(d in Document, where: d.id in ^[ctx.both.id, ctx.security_only.id]),
      set: [title: "Same"]
    )

    assert {:ok, first} = query("document", %{query: "Same", limit: 1}, ctx.context)
    assert {:ok, second} = query("document", %{query: "Same", limit: 1, offset: 1}, ctx.context)
    assert ids(first) ++ ids(second) == [ctx.both.id, ctx.security_only.id]

    assert {:ok, result} =
             query(
               "document",
               %{
                 filters: %{
                   "source" => ctx.both.source,
                   "content_type" => "markdown",
                   "label_ids" => [ctx.security.id]
                 }
               },
               ctx.context
             )

    assert ids(result) == [ctx.both.id]
  end

  property "duplicate IDs and input ordering preserve any/all sets and never expose unreadable rows",
           ctx do
    check all(
            indexes <- list_of(member_of([0, 1]), max_length: 12),
            match <- member_of(["any", "all"]),
            max_runs: 20
          ) do
      labels = [ctx.security.id, ctx.architecture.id]
      requested = Enum.map(indexes, &Enum.at(labels, &1))

      sets = [
        {ctx.both.id, labels},
        {ctx.security_only.id, [ctx.security.id]},
        {ctx.removed.id, [ctx.architecture.id]}
      ]

      expected =
        for {id, assigned} <- sets,
            requested != [] and
              if(match == "all",
                do: Enum.all?(requested, &(&1 in assigned)),
                else: Enum.any?(requested, &(&1 in assigned))
              ),
            do: id

      assert {:ok, result} =
               query(
                 "document",
                 %{filters: %{"label_ids" => requested, "label_match" => match}},
                 ctx.context
               )

      assert ids(result) == expected
      assert result.total_count == length(expected)
    end
  end

  test "document and label queries dispatch only query params and trusted context to Ingestion",
       ctx do
    for type <- ["document", "label"] do
      expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
        assert event.next_hop.destination == :ingestion
        assert event.opts[:action] == :query_resources
        assert event.opts[:confidential] == true
        assert event.opts[:skip_permissions] == false
        assert event.opts[:person_id] == ctx.person.id
        assert event.opts[:team_ids] == [17]
        assert event.actor == ctx.context.actor
        assert event.request == %{mode: "query", resource_type: type, fields: ["id"]}
        %{event | response: {:error, {:service_unavailable, :ingestion}}}
      end)

      assert {:error, {:service_unavailable, :ingestion}} =
               query(
                 type,
                 %{
                   fields: ["id"],
                   skip_permissions: true,
                   actor: %{person_id: 999},
                   module: Zaq.Accounts.User
                 },
                 Map.merge(ctx.context, %{
                   node_router: Zaq.NodeRouterMock,
                   person_id: ctx.person.id,
                   team_ids: [17]
                 })
               )
    end
  end

  test "Ingestion query boundary ignores request and actor permission bypass", ctx do
    request = %{
      resource_type: "document",
      fields: ["id"],
      skip_permissions: true,
      context: %{skip_permissions: true},
      actor: %{skip_permissions: true}
    }

    event =
      Zaq.Event.new(request, :ingestion,
        actor: Map.put(ctx.context.actor, :skip_permissions, true),
        opts: [action: :query_resources, confidential: true]
      )

    assert %{response: {:ok, result}} =
             Api.handle_event(event, :query_resources, nil)

    refute ctx.private.id in ids(result)
    assert ctx.both.id in ids(result)

    trusted = %{event | opts: Keyword.put(event.opts, :skip_permissions, true)}

    assert %{response: {:ok, result}} =
             Api.handle_event(trusted, :query_resources, nil)

    assert ctx.private.id in ids(result)
  end

  property "Ingestion query boundary rejects resource keys outside its own allowlist" do
    check all(type <- string(:alphanumeric, min_length: 1), type not in ["document", "label"]) do
      event = Zaq.Event.new(%{resource_type: type}, :ingestion, opts: [skip_permissions: true])

      assert %{response: {:error, {:unknown_resource_type, ^type}}} =
               Api.handle_event(event, :query_resources, nil)
    end
  end

  defp query(type, params, context),
    do: QueryResources.run(Map.merge(%{mode: "query", resource_type: type}, params), context)

  defp ids(result), do: Enum.map(result.resources, & &1.id)

  defp label(actor, name) do
    {:ok, label} =
      label_definition(actor, %{
        name: name,
        description: "About #{name}",
        value_type: "options",
        value_config: option_config(["Unspecified", "Paris", "Secret", "Finance", "London"])
      })

    label
  end

  defp document(title, actor, assignments) do
    {:ok, document} =
      Document.create(%{
        title: title,
        source: "query-labels/#{title}",
        content: "private content",
        metadata: %{private: true}
      })

    {:ok, _} =
      Labels.edit_resource(
        %{type: "document", id: document.id},
        Enum.map(assignments, fn {label, selected} ->
          %{
            label_id: label.id,
            operation: if(selected, do: "add", else: "remove"),
            value: "Unspecified",
            expected_version: 0
          }
        end),
        actor
      )

    document
  end
end

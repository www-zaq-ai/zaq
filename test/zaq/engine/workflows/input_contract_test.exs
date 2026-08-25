defmodule Zaq.Engine.Workflows.InputContractTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Workflows.Action
  alias Zaq.Engine.Workflows.InputContract
  alias Zaq.Engine.Workflows.Placeholders
  alias Zaq.Engine.Workflows.Step.Edge, as: StepEdge
  alias Zaq.Engine.Workflows.Step.Node, as: StepNode
  alias Zaq.Engine.Workflows.Workflow

  defp graph(nodes, edges), do: %{"nodes" => nodes, "edges" => edges}

  # History declares no required fields, so a fixture only shows what it sets up.
  defp step(name, opts \\ []) do
    %{
      "name" => name,
      "module" => Keyword.get(opts, :module, "Zaq.Agent.Tools.Accounts.History"),
      "params" => Keyword.get(opts, :params, %{})
    }
  end

  defp edge(from, to, mapping \\ %{}), do: %{"from" => from, "to" => to, "mapping" => mapping}

  defp sorted(set), do: set |> MapSet.to_list() |> Enum.sort()

  describe "all_inputs/1 and fed_by_steps/1 — the formula" do
    test "a mapping target is an input; a step-rooted source feeds it" do
      g = graph([step("a"), step("b")], [edge("a", "b", %{"query" => "a.messages"})])

      assert sorted(InputContract.all_inputs(g)) == ["b.query"]
      assert sorted(InputContract.fed_by_steps(g)) == ["b.query"]
      assert sorted(InputContract.missing(g)) == []
    end

    test "start is not a step, so a start source survives the difference" do
      g = graph([step("a"), step("b")], [edge("a", "b", %{"query" => "start.email topic"})])

      assert sorted(InputContract.all_inputs(g)) == ["b.query"]
      assert sorted(InputContract.fed_by_steps(g)) == []
      assert sorted(InputContract.missing(g)) == ["b.query"]

      # The subtraction is where it comes from; required vs optional is what the
      # target field declares. `History.query` is optional, so the payload may
      # omit it — it is still a path the workflow reads.
      assert InputContract.required_inputs(g) == []
      assert InputContract.optional_inputs(g) == ["email topic"]
    end

    test "a start source reaching a required field is a required input" do
      g =
        graph(
          [step("a"), step("b", module: "Zaq.Agent.Tools.Workflow.Concat")],
          [edge("a", "b", %{"parts" => "start.email topic"})]
        )

      assert sorted(InputContract.missing(g)) == ["b.parts"]
      assert InputContract.required_inputs(g) == ["email topic"]
      assert InputContract.optional_inputs(g) == []
    end

    test "only the 'to' side of an edge names the node being fed" do
      g = graph([step("a"), step("b")], [edge("a", "b", %{"row" => "a.row"})])

      assert sorted(InputContract.all_inputs(g)) == ["b.row"]
    end

    test "a field written from both start and a step is not fed" do
      g =
        graph(
          [step("a"), step("b", module: "Zaq.Agent.Tools.Workflow.Concat")],
          [edge("a", "b", %{"parts" => "a.messages"})]
        )

      # A placeholder in any param is a reference — `StepRunner` resolves them all —
      # but it is keyed by its own field, so it does not unfeed the mapped `parts`.
      g = put_in(g, ["nodes", Access.at(1), "params"], %{"other" => "{{start.topic}}"})
      assert sorted(InputContract.fed_by_steps(g)) == ["b.parts"]
      assert InputContract.required_inputs(g) == ["topic"]

      g = put_in(g, ["nodes", Access.at(1), "params"], %{"parts" => "{{start.topic}}"})
      assert sorted(InputContract.fed_by_steps(g)) == []
      assert InputContract.required_inputs(g) == ["topic"]
    end

    test "a field read by several nodes is required once" do
      g =
        graph(
          [step("a"), step("b"), step("c")],
          [
            edge("a", "b", %{"x" => "start.topic"}),
            edge("b", "c", %{"y" => "start.topic"})
          ]
        )

      assert sorted(InputContract.missing(g)) == ["b.x", "c.y"]
      assert InputContract.required_inputs(g) == ["topic"]
    end

    test "a nested start path keeps every segment" do
      g = graph([step("a"), step("b")], [edge("a", "b", %{"n" => "start.input.name"})])

      assert InputContract.required_inputs(g) == ["input.name"]
    end
  end

  describe "params" do
    test "a pinned param settles a schema field nothing maps over" do
      g =
        graph(
          [step("a", module: "Zaq.Agent.Tools.Workflow.Concat", params: %{"parts" => "x"})],
          []
        )

      assert sorted(InputContract.all_inputs(g)) == []
    end

    test "a pinned param does not settle a field a mapping writes over" do
      # EdgeStep applies the mapping over the node's params, so the default loses.
      g =
        graph(
          [step("a"), step("b", params: %{"query" => "a default"})],
          [edge("a", "b", %{"query" => "start.email topic"})]
        )

      assert sorted(InputContract.all_inputs(g)) == ["b.query"]
      assert InputContract.optional_inputs(g) == ["email topic"]
    end

    test "a Concat placeholder is a reference" do
      g =
        graph(
          [
            step("a",
              module: "Zaq.Agent.Tools.Workflow.Concat",
              params: %{"parts" => ["{{start.topic}}"]}
            )
          ],
          []
        )

      assert sorted(InputContract.all_inputs(g)) == ["a.parts"]
      assert InputContract.required_inputs(g) == ["topic"]
    end

    test "placeholders are found in strings nested at any depth" do
      g =
        graph(
          [
            step("a",
              module: "Zaq.Agent.Tools.Workflow.Concat",
              params: %{"parts" => [[%{"content" => "{{start.company context content}}"}]]}
            )
          ],
          []
        )

      assert InputContract.required_inputs(g) == ["company context content"]
    end

    test "a Condition input is a reference like any other action's" do
      g =
        graph(
          [
            step("a"),
            step("b",
              module: "Zaq.Agent.Tools.Workflow.Condition",
              params: %{"input" => "{{a.metadata}}"}
            )
          ],
          [edge("a", "b")]
        )

      assert sorted(InputContract.fed_by_steps(g)) == ["b.input"]
      assert InputContract.required_inputs(g) == []
    end

    test "a Condition key that is a path inside the input value is not an input" do
      g =
        graph(
          [
            step("a"),
            step("b",
              module: "Zaq.Agent.Tools.Workflow.Condition",
              params: %{
                "input" => "{{a.metadata}}",
                "conditions" => [%{"key" => "total.last_message_date", "op" => "gte"}]
              }
            )
          ],
          [edge("a", "b")]
        )

      # `Condition` evaluates each key against the input `StepRunner` resolved —
      # here `a.metadata` — with `__cascade__` merged in. `total` is a key of that
      # value, so it is run-time data the graph says nothing about, not an input.
      assert sorted(InputContract.all_inputs(g)) == ["b.input"]
      assert InputContract.required_inputs(g) == []
      assert InputContract.unsatisfiable_inputs(g) == []
    end

    test "a bare Condition key is a top-level key of the input value, not an input" do
      g =
        graph(
          [
            step("a"),
            step("b",
              module: "Zaq.Agent.Tools.Workflow.Condition",
              params: %{
                "input" => "{{a.metadata}}",
                "conditions" => [%{"key" => "active", "value" => true}]
              }
            )
          ],
          [edge("a", "b")]
        )

      # The commonest real shape: `active` is a plain key of the map being
      # evaluated. It never reaches the graph, so it is neither required nor
      # unsatisfiable.
      assert sorted(InputContract.all_inputs(g)) == ["b.input"]
      assert InputContract.required_inputs(g) == []
      assert InputContract.unsatisfiable_inputs(g) == []
    end

    test "a Condition key is never a reference, whatever its root names" do
      g =
        graph(
          [
            step("a"),
            step("b",
              module: "Zaq.Agent.Tools.Workflow.Condition",
              params: %{
                "input" => "{{a.metadata}}",
                "conditions" => [
                  %{"key" => "a.messages", "value" => 1},
                  %{"key" => "start.sequence", "value" => 4}
                ]
              }
            )
          ],
          [edge("a", "b")]
        )

      # Both roots name something in the graph — a node and the trigger namespace —
      # and neither makes the key a reference. A key selects inside `input`, so
      # renaming node `a` cannot turn `a.messages` into a payload requirement.
      assert sorted(InputContract.all_inputs(g)) == ["b.input"]
      assert InputContract.required_inputs(g) == []
      assert InputContract.unsatisfiable_inputs(g) == []
    end

    test "a `{{...}}` inside a condition value is a requirement like any other" do
      # `StepRunner` walks list and map params alike, so a placeholder nested in
      # `conditions[].value` resolves — and the contract sees it.
      g =
        graph(
          [
            step("a",
              module: "Zaq.Agent.Tools.Workflow.Condition",
              params: %{
                "input" => %{"tier" => "gold"},
                "conditions" => [%{"key" => "tier", "value" => "{{start.tier}}"}]
              }
            )
          ],
          []
        )

      assert sorted(InputContract.all_inputs(g)) == ["a.conditions"]

      # `conditions` is optional on `Condition`, so the path it reaches is optional
      # too — read by the graph, not owed by the payload.
      assert InputContract.optional_inputs(g) == ["tier"]
    end

    test "a Condition input reading start is required from the payload" do
      g =
        graph(
          [
            step("a",
              module: "Zaq.Agent.Tools.Workflow.Condition",
              params: %{"input" => "{{start.row}}"}
            )
          ],
          []
        )

      assert InputContract.required_inputs(g) == ["row"]
    end

    test "a `{{...}}` in a Condition param is a requirement like any other" do
      # `StepRunner` resolves placeholders for every action alike, `Condition`
      # included, so a `{{...}}` in its params is a real reference the payload must
      # satisfy — not the phantom it was when each action substituted its own.
      g =
        graph(
          [
            step("a",
              module: "Zaq.Agent.Tools.Workflow.Condition",
              params: %{
                "input" => "{{start.tier}}",
                "conditions" => [%{"key" => "{{start.plan}}", "value" => true}]
              }
            )
          ],
          []
        )

      # `input` is required on `Condition` and `conditions` is not, so the two
      # placeholders land in different buckets — both are read, only one must be sent.
      assert InputContract.required_inputs(g) == ["tier"]
      assert InputContract.optional_inputs(g) == ["plan"]
    end

    test "any action's params are scanned — no module list decides it" do
      # The old `@placeholder_sites` table named which modules/params to scan, so a
      # new placeholder-resolving action was silently missed. `StepRunner` now
      # resolves every action's params, so the contract scans every action's params.
      g =
        graph(
          [
            step("a",
              module: "Zaq.Agent.Tools.Accounts.History",
              params: %{"q" => "{{start.a}}"}
            ),
            step("b",
              module: "Zaq.Agent.Tools.Workflow.Concat",
              params: %{"parts" => ["x"], "sep" => "{{start.b}}"}
            )
          ],
          []
        )

      assert InputContract.required_inputs(g) == ["a", "b"]
    end

    test "the contract reads a reference exactly as DagBuilder decides to resolve one" do
      # Both go through `Placeholders.references/1`. If they ever diverged, the
      # contract would demand a payload key the run never reads, or miss one it does.
      params = %{
        "parts" => ["a literal, so Concat's required field is pinned"],
        "input" => "{{start.topic}}",
        "nested" => %{"deep" => ["{{start.name}}"]},
        "literal" => "no reference here",
        "plumbing" => "{{__cascade__}}"
      }

      g = graph([step("a", module: "Zaq.Agent.Tools.Workflow.Concat", params: params)], [])

      scanned =
        for {key, value} <- params, Placeholders.references(value) != [], do: key

      assert Enum.sort(scanned) == ["input", "nested"]
      assert InputContract.required_inputs(g) == ["name", "topic"]
    end

    # `InputContract` names no module. A bare dotted string is data whatever module
    # it sits on — `Condition` included, now that its `input` uses `{{...}}` and its
    # `conditions[].key` is a selector into that input.
    test "a bare dotted Condition param needs no module-specific knowledge" do
      g =
        graph(
          [
            step("a",
              module: "Zaq.Agent.Tools.Workflow.Condition",
              params: %{"input" => "start.row"}
            )
          ],
          []
        )

      assert InputContract.required_inputs(g) == []
    end

    test "a dotted param on a module that does not resolve references is data" do
      g = graph([step("a", params: %{"query" => "start.email topic"})], [])

      assert sorted(InputContract.all_inputs(g)) == []
      assert InputContract.required_inputs(g) == []
    end

    test "a bare placeholder naming a locally-written key is not a payload requirement" do
      # `{{row}}` reads the key the incoming mapping writes.
      g =
        graph(
          [
            step("a"),
            step("b",
              module: "Zaq.Agent.Tools.Workflow.Concat",
              params: %{"parts" => ["{{row}}"]}
            )
          ],
          [edge("a", "b", %{"row" => "a.row"})]
        )

      assert InputContract.required_inputs(g) == []
      assert InputContract.unsatisfiable_inputs(g) == []
    end
  end

  describe "schema-required fields" do
    test "an entry node's unwritten required field comes from the payload" do
      g = graph([step("a", module: "Zaq.Agent.Tools.Workflow.Concat")], [])

      assert sorted(InputContract.all_inputs(g)) == ["a.parts"]
      assert InputContract.required_inputs(g) == ["parts"]
    end

    test "a mid-DAG required field no predecessor emits is unsatisfiable" do
      g =
        graph(
          [step("a"), step("b", module: "Zaq.Agent.Tools.Workflow.Concat")],
          [edge("a", "b")]
        )

      # `History` declares no `parts` in its output schema, so nothing feeds it and
      # no payload can either — a mid-DAG node never reads `start` at the fact root.
      assert InputContract.unsatisfiable_inputs(g) == [
               %{node: "b", field: "parts", source: nil}
             ]

      assert InputContract.required_inputs(g) == []
    end

    test "a mid-DAG required field the predecessor's output schema declares is fed" do
      g =
        graph(
          [
            step("a", module: "Zaq.Agent.Tools.Sheets.GetSheet"),
            step("b", module: "Zaq.Agent.Tools.Sheets.ExtractRows")
          ],
          [edge("a", "b")]
        )

      # `GetSheet` declares `record`, `ExtractRows` requires it, and `StepRunner`
      # passes the whole fact down the edge — so the unmapped edge is complete.
      assert "record" in InputContract.emitted_schema_fields("Zaq.Agent.Tools.Sheets.GetSheet")
      assert sorted(InputContract.fed_by_steps(g)) == ["b.record"]
      assert InputContract.unsatisfiable_inputs(g) == []

      # `a` is the entry node, so its own required params still come from the
      # payload — but `record` never does.
      assert InputContract.required_inputs(g) == ["provider", "spreadsheet_id"]
    end

    test "a mapping source naming a predecessor's declared output key is fed" do
      g =
        graph(
          [
            step("a", module: "Zaq.Agent.Tools.Sheets.ExtractRows"),
            step("b")
          ],
          [edge("a", "b", %{"items" => "rows"})]
        )

      # A bare source is a key of the incoming fact; `ExtractRows` declares `rows`.
      assert sorted(InputContract.fed_by_steps(g)) == ["b.items"]
      assert InputContract.unsatisfiable_inputs(g) == []
    end

    test "a mapping source no predecessor declares is unsatisfiable, and names itself" do
      g =
        graph(
          [
            step("a", module: "Zaq.Agent.Tools.Sheets.ExtractRows"),
            step("b")
          ],
          [edge("a", "b", %{"items" => "zzz.rows"})]
        )

      assert InputContract.unsatisfiable_inputs(g) == [
               %{node: "b", field: "items", source: "zzz.rows"}
             ]
    end

    test "a param pinned to nil does not satisfy a required field" do
      pinned = fn value ->
        graph([step("a", module: "Zaq.Agent.Tools.Sheets.GetSheet", params: value)], [])
      end

      # A key present with `nil` is not a value — the run would read `nil` and fail
      # exactly the way the contract exists to catch. `check/2` applies the same rule
      # to a payload: see "a key present but nil is missing" below.
      assert InputContract.required_inputs(pinned.(%{"provider" => nil})) ==
               ["provider", "spreadsheet_id"]

      # An empty string is a value an author can mean, so it still pins.
      assert InputContract.required_inputs(pinned.(%{"provider" => ""})) == ["spreadsheet_id"]

      assert InputContract.required_inputs(pinned.(%{"provider" => "google_drive"})) ==
               ["spreadsheet_id"]
    end

    test "an optional schema field is never an input" do
      g = graph([step("a", module: "Zaq.Agent.Tools.Accounts.History")], [])

      assert sorted(InputContract.all_inputs(g)) == []
    end

    test "reads required fields from both schema dialects" do
      assert InputContract.required_schema_fields("Zaq.Agent.Tools.Workflow.Concat") == ["parts"]

      assert InputContract.required_schema_fields("Zaq.Agent.Tools.People.EnsurePerson") == [
               "platform"
             ]

      assert InputContract.required_schema_fields("Not.A.Module") == []
      assert InputContract.required_schema_fields(nil) == []
    end
  end

  describe "required_schema_field_specs/1" do
    test "a Zoi-declared required field comes back with a spec that judges its type" do
      specs = InputContract.required_schema_field_specs("Zaq.Agent.Tools.People.UpdatePerson")

      assert {"person_id", spec} = List.keyfind(specs, "person_id", 0)
      assert InputContract.spec_accepts?(spec, 42)
      refute InputContract.spec_accepts?(spec, "42")
    end

    test "a keyword-declared required field does too — both dialects are read" do
      specs = InputContract.required_schema_field_specs("Zaq.Agent.Tools.Sheets.GetSheet")

      assert {"provider", spec} = List.keyfind(specs, "provider", 0)
      assert InputContract.spec_accepts?(spec, "google_drive")
      refute InputContract.spec_accepts?(spec, 42)
    end

    test "a structured keyword type is judged structurally, not by name" do
      specs =
        InputContract.required_schema_field_specs("Zaq.Agent.Tools.Sheets.UpdateSheetValues")

      assert {"values", spec} = List.keyfind(specs, "values", 0)
      assert InputContract.spec_accepts?(spec, [["a", "b"], ["c"]])
      refute InputContract.spec_accepts?(spec, "a,b")
    end

    test "a module that declares nothing readable yields no specs" do
      for module <- [nil, "", "Not.A.Module", "Zaq.Engine.Workflows.InputContract"] do
        assert InputContract.required_schema_field_specs(module) == []
      end
    end

    # One producer for both views, so the names and the specs cannot drift apart.
    test "required_schema_fields/1 is exactly the names of the specs" do
      for module <- [
            "Zaq.Agent.Tools.People.UpdatePerson",
            "Zaq.Agent.Tools.Sheets.GetSheet",
            "Zaq.Agent.Tools.Accounts.History",
            "Not.A.Module"
          ] do
        assert InputContract.required_schema_fields(module) ==
                 module |> InputContract.required_schema_field_specs() |> Enum.map(&elem(&1, 0))
      end
    end

    test "an optional field is not a spec — only required fields are contract material" do
      names =
        "Zaq.Agent.Tools.DataSource.SearchDocuments"
        |> InputContract.required_schema_field_specs()
        |> Enum.map(&elem(&1, 0))

      assert names == ["provider", "query"]
    end
  end

  describe "spec_accepts?/2" do
    test "nil is never judged here — presence is check/2's question, not the spec's" do
      [{"person_id", spec}] =
        InputContract.required_schema_field_specs("Zaq.Agent.Tools.People.UpdatePerson")

      refute InputContract.spec_accepts?(spec, nil)
    end

    test "an :any-typed field accepts anything" do
      specs = InputContract.required_schema_field_specs("Zaq.Agent.Tools.Workflow.Concat")

      assert {"parts", spec} = List.keyfind(specs, "parts", 0)
      assert InputContract.spec_accepts?(spec, ["a", "b"])
    end
  end

  # A payload path is type-checked only where its value reaches a schema-typed field
  # whole. Everything else keeps presence-only semantics, and says so by carrying no
  # expectation at all.
  describe "expectations/1 — which required paths carry a type" do
    test "a schema-required field of an entry node types its payload path" do
      g = graph([step("a", module: "Zaq.Agent.Tools.Sheets.GetSheet")], [])

      assert %{"provider" => [_ | _], "spreadsheet_id" => [_ | _]} =
               InputContract.expectations(g)
    end

    test "a mapping delivers its source whole, so the target field types the path" do
      g =
        graph(
          [step("a"), step("b", module: "Zaq.Agent.Tools.Sheets.GetSheet")],
          [edge("a", "b", %{"provider" => "start.which provider"})]
        )

      assert [spec] = InputContract.expectations(g)["which provider"]
      assert InputContract.spec_accepts?(spec, "google_drive")
      refute InputContract.spec_accepts?(spec, 42)
    end

    test "a lone placeholder param types its path" do
      g =
        graph(
          [
            step("a",
              module: "Zaq.Agent.Tools.Sheets.GetSheet",
              params: %{"provider" => "{{start.which provider}}", "spreadsheet_id" => "s"}
            )
          ],
          []
        )

      assert [spec] = InputContract.expectations(g)["which provider"]
      refute InputContract.spec_accepts?(spec, 42)
    end

    # `"sheet {{start.which provider}}"` resolves to a string whatever the payload
    # holds, so the field's declared type says nothing about the payload's.
    test "an interpolated placeholder types nothing" do
      g =
        graph(
          [
            step("a",
              module: "Zaq.Agent.Tools.Sheets.GetSheet",
              params: %{
                "provider" => "sheet {{start.which provider}}",
                "spreadsheet_id" => "s"
              }
            )
          ],
          []
        )

      assert InputContract.expectations(g)["which provider"] == nil
    end

    test "a condition field types nothing — a condition has no schema" do
      g =
        graph(
          [step("a"), step("b")],
          [%{"from" => "start", "to" => "a", "mapping" => %{}, "condition" => %{"field" => "go"}}]
        )

      assert InputContract.expectations(g)["go"] == nil
    end

    test "two nodes needing one path with different types collect both" do
      g =
        graph(
          [
            step("a", module: "Zaq.Agent.Tools.Sheets.GetSheet"),
            step("b", module: "Zaq.Agent.Tools.People.UpdatePerson")
          ],
          [
            edge("start", "a", %{"provider" => "start.shared"}),
            edge("start", "b", %{"person_id" => "start.shared"})
          ]
        )

      assert [_, _] = InputContract.expectations(g)["shared"]
    end

    test "every typed path is a required input — the two views agree" do
      g = graph([step("a", module: "Zaq.Agent.Tools.Sheets.GetSheet")], [])
      required = InputContract.required_inputs(g)

      assert g
             |> InputContract.expectations()
             |> Map.keys()
             |> Enum.sort()
             |> Enum.all?(&(&1 in required))
    end
  end

  describe "check/2" do
    test "reports a payload that supplies everything as valid" do
      assert %{valid: true, missing_inputs: []} =
               InputContract.check(["topic"], %{"topic" => "x"})
    end

    test "reports the paths a payload does not supply" do
      assert %{valid: false, missing_inputs: ["language", "topic"], supplied: ["name"]} =
               InputContract.check(["topic", "name", "language"], %{"name" => "Saraluna"})
    end

    test "an empty contract is satisfied by any payload" do
      assert %{valid: true} = InputContract.check([], %{})
    end

    test "resolves a nested path" do
      assert %{valid: true} = InputContract.check(["input.name"], %{"input" => %{"name" => "x"}})
    end

    test "a nested path missing its parent is reported" do
      assert %{valid: false, missing_inputs: ["input.name"]} =
               InputContract.check(["input.name"], %{"name" => "x"})
    end

    test "accepts a differently-cased key, the way FactLookup will at run time" do
      assert %{valid: true} =
               InputContract.check(["company context content"], %{
                 "Company Context Content" => "x"
               })
    end

    test "accepts underscores for spaces" do
      assert %{valid: true} = InputContract.check(["email topic"], %{"email_topic" => "x"})
    end

    test "accepts an atom-keyed payload" do
      assert %{valid: true} = InputContract.check(["topic"], %{topic: "x"})
    end

    # The mirror of "a param pinned to nil does not satisfy a required field" above:
    # `nil` is not a value on either side of the contract.
    test "a key present but nil is missing" do
      assert %{valid: false, missing_inputs: ["topic"], supplied: []} =
               InputContract.check(["topic"], %{"topic" => nil})
    end

    test "a value an author can mean still counts as supplied" do
      assert %{valid: true} = InputContract.check(["topic"], %{"topic" => false})
      assert %{valid: true} = InputContract.check(["topic"], %{"topic" => 0})
      assert %{valid: true} = InputContract.check(["topic"], %{"topic" => ""})
    end

    test "a nested leaf present but nil is missing" do
      assert %{valid: false, missing_inputs: ["input.name"]} =
               InputContract.check(["input.name"], %{"input" => %{"name" => nil}})

      assert %{valid: true} = InputContract.check(["input.name"], %{"input" => %{"name" => "x"}})
    end

    # The path resolves — only then is its value judged. A canonicalising match that
    # lands on `nil` is missing, not supplied because the key was found.
    test "a canonicalised key present but nil is missing" do
      assert %{valid: false, missing_inputs: ["email topic"]} =
               InputContract.check(["email topic"], %{"Email_Topic" => nil})
    end

    # The footgun the tool exists to catch: `required_input_shape/1` hands an agent a
    # skeleton with `nil` leaves, and sending it back unfilled must not read as valid.
    test "the unfilled required_input_shape satisfies nothing" do
      g =
        graph(
          [step("a", module: "Zaq.Agent.Tools.Sheets.GetSheet")],
          []
        )

      shape = InputContract.required_input_shape(g)
      required = InputContract.required_inputs(g)

      assert %{valid: false, missing_inputs: ^required, supplied: []} =
               InputContract.check(g, shape)
    end

    test "a scalar payload supplies nothing" do
      assert %{valid: false, missing_inputs: ["topic"]} =
               InputContract.check(["topic"], "a string")
    end

    test "accepts a workflow directly" do
      g = graph([step("a"), step("b")], [edge("a", "b", %{"q" => "start.topic"})])

      assert %{valid: true} = InputContract.check(g, %{"topic" => "x"})
      assert %{valid: false, missing_inputs: ["topic"]} = InputContract.check(g, %{})
    end
  end

  # The contract reads a schema's field names *and* its types, so it answers both
  # "is this path supplied?" and "is it the right kind of value?". A wrong-typed value
  # is reported apart from a missing one: the remediation differs.
  describe "a required field's declared type is part of the contract" do
    defp updates_person,
      do: graph([step("a", module: "Zaq.Agent.Tools.People.UpdatePerson")], [])

    test "the schema's required integer field is a required input" do
      assert InputContract.required_inputs(updates_person()) == ["person_id"]
    end

    test "an integer satisfies it" do
      assert %{valid: true, missing_inputs: [], invalid_inputs: []} =
               InputContract.check(updates_person(), %{"person_id" => 42})
    end

    test "a string where the schema wants an integer is invalid, not supplied" do
      assert %{valid: false, missing_inputs: [], supplied: []} =
               result = InputContract.check(updates_person(), %{"person_id" => "42"})

      assert [%{path: "person_id", expected: "integer", got: "string"}] = result.invalid_inputs
    end

    test "every other wrong-typed value is invalid too" do
      for wrong <- [%{"id" => 42}, ["42"], true, 4.2, "42"] do
        assert %{valid: false, invalid_inputs: [%{path: "person_id"}]} =
                 InputContract.check(updates_person(), %{"person_id" => wrong})
      end
    end

    # The two buckets never mix: `nil` is the absence of a value, not a wrong one, and
    # its remediation is "send a value" rather than "send the right kind of value".
    test "null is missing, never invalid" do
      assert %{valid: false, missing_inputs: ["person_id"], invalid_inputs: [], supplied: []} =
               InputContract.check(updates_person(), %{"person_id" => nil})
    end

    test "a payload can be missing one path and wrong-typed on another" do
      g =
        graph(
          [
            step("a", module: "Zaq.Agent.Tools.People.UpdatePerson"),
            step("b", module: "Zaq.Agent.Tools.Sheets.GetSheet")
          ],
          []
        )

      result = InputContract.check(g, %{"person_id" => "42", "provider" => "google_drive"})

      assert result.valid == false
      assert result.missing_inputs == ["spreadsheet_id"]
      assert [%{path: "person_id"}] = result.invalid_inputs
      assert result.supplied == ["provider"]
    end

    test "a keyword-declared string field is judged too — both dialects" do
      g = graph([step("a", module: "Zaq.Agent.Tools.Sheets.GetSheet")], [])

      assert %{valid: false, invalid_inputs: [%{path: "provider", got: "integer"}]} =
               InputContract.check(g, %{"provider" => 42, "spreadsheet_id" => "s"})

      assert %{valid: true} =
               InputContract.check(g, %{"provider" => "google_drive", "spreadsheet_id" => "s"})
    end

    test "a path two nodes read must satisfy both of their types" do
      g =
        graph(
          [
            step("a", module: "Zaq.Agent.Tools.Sheets.GetSheet"),
            step("b", module: "Zaq.Agent.Tools.People.UpdatePerson")
          ],
          [
            edge("start", "a", %{"provider" => "start.shared"}),
            edge("start", "b", %{"person_id" => "start.shared"})
          ]
        )

      # No value is both a string and an integer, so either type refuses one of them.
      assert %{valid: false, invalid_inputs: [%{path: "shared"}]} =
               InputContract.check(g, %{"shared" => "google_drive", "spreadsheet_id" => "s"})

      assert %{valid: false, invalid_inputs: [%{path: "shared"}]} =
               InputContract.check(g, %{"shared" => 42, "spreadsheet_id" => "s"})
    end

    # Narrowing only where a type is actually knowable: an interpolated reference
    # resolves to a string whatever the payload holds, so nothing is claimed about it.
    test "a path reached only through an interpolated placeholder keeps presence-only" do
      g =
        graph(
          [
            step("a",
              module: "Zaq.Agent.Tools.Sheets.GetSheet",
              params: %{"provider" => "sheet {{start.which}}", "spreadsheet_id" => "s"}
            )
          ],
          []
        )

      assert %{valid: true, invalid_inputs: []} = InputContract.check(g, %{"which" => 42})
    end

    # Without a graph there are no modules and so no types — the list arity keeps the
    # presence-only semantics it has always had, and says so.
    test "check/2 on a bare list of paths type-checks nothing" do
      assert %{valid: true, invalid_inputs: []} =
               InputContract.check(["person_id"], %{"person_id" => "42"})
    end

    test "contract/2 reports both buckets in one pass" do
      assert %{valid: false, missing_inputs: [], invalid_inputs: [%{path: "person_id"}]} =
               InputContract.contract(updates_person(), %{"person_id" => "42"})

      assert %{valid: true, invalid_inputs: []} =
               InputContract.contract(updates_person(), %{"person_id" => 42})
    end
  end

  # `AddSheetTab` is the shape the question asks about: three required fields
  # (`provider`, `spreadsheet_id`, `title`) plus an optional `index` the schema
  # declares as an integer. The field is optional in the sense that it may be
  # absent — not in the sense that any value will do, which is why `StepRunner`
  # refuses a wrong-kinded one at run time whether or not it was required.
  describe "an optional field the graph wires is type-checked too" do
    @add_tab "Zaq.Agent.Tools.Sheets.AddSheetTab"

    defp required_tab_params,
      do: %{"provider" => "google_drive", "spreadsheet_id" => "s", "title" => "Q3"}

    defp wired_optional(source) do
      graph(
        [step("a", module: @add_tab)],
        [edge("start", "a", %{"index" => source})]
      )
    end

    test "wiring it from the payload makes it an optional input, not a required one" do
      g = wired_optional("start.index")

      assert InputContract.required_inputs(g) == ["provider", "spreadsheet_id", "title"]
      assert InputContract.optional_inputs(g) == ["index"]
    end

    test "omitting the wired optional field is valid" do
      assert %{valid: true, missing_inputs: [], invalid_inputs: []} =
               InputContract.check(wired_optional("start.index"), required_tab_params())
    end

    test "an integer satisfies the wired optional field" do
      assert %{valid: true, invalid_inputs: []} =
               InputContract.check(
                 wired_optional("start.index"),
                 Map.put(required_tab_params(), "index", 3)
               )
    end

    test "a string where the optional field declares an integer is invalid" do
      result =
        InputContract.check(
          wired_optional("start.index"),
          Map.put(required_tab_params(), "index", "3")
        )

      assert %{valid: false, missing_inputs: []} = result
      assert [%{path: "index", expected: "integer", got: "string"}] = result.invalid_inputs
    end

    test "the same field reached as a lone param reference is judged the same way" do
      g =
        graph(
          [
            step("a",
              module: @add_tab,
              params: Map.put(required_tab_params(), "index", "{{start.index}}")
            )
          ],
          []
        )

      assert %{valid: false, invalid_inputs: [%{path: "index", got: "string"}]} =
               InputContract.check(g, %{"index" => "3"})

      assert %{valid: true, invalid_inputs: []} = InputContract.check(g, %{"index" => 3})
    end

    # The agreement the contract exists to make: what it calls valid is what the
    # run accepts. `StepRunner` validates every declared field, required or not,
    # so a verdict the contract reaches on an optional field must match it.
    test "the contract's verdict matches what StepRunner would do with the same value" do
      [{"index", spec, false}] =
        Enum.filter(Action.field_specs(@add_tab), &(elem(&1, 0) == "index"))

      refute InputContract.spec_accepts?(spec, "3")
      assert InputContract.spec_accepts?(spec, 3)

      assert %{valid: false} =
               InputContract.check(
                 wired_optional("start.index"),
                 Map.put(required_tab_params(), "index", "3")
               )
    end
  end

  describe "normalisation" do
    test "a Workflow struct derives identically to its snapshot" do
      nodes = [
        %StepNode{name: "a", type: "action", module: "M", index: 0, params: %{k: "v"}},
        %StepNode{name: "b", type: "action", module: "M", index: 1, params: %{}}
      ]

      edges = [%StepEdge{from: "a", to: "b", mapping: %{"q" => "start.topic"}, condition: nil}]

      from_struct = InputContract.required_inputs(%Workflow{nodes: nodes, edges: edges})

      from_snapshot =
        InputContract.required_inputs(
          graph(
            [step("a", module: "M", params: %{"k" => "v"}), step("b", module: "M")],
            [edge("a", "b", %{"q" => "start.topic"})]
          )
        )

      assert from_struct == from_snapshot
      assert from_struct == ["topic"]
    end

    test "atom-keyed mappings and params are stringified" do
      g = %{
        "nodes" => [%{name: "a", module: "M", params: %{k: "v"}}, %{name: "b", module: "M"}],
        "edges" => [%{from: "a", to: "b", mapping: %{q: :"start.topic"}}]
      }

      assert InputContract.required_inputs(g) == ["topic"]
    end

    test "an empty workflow needs nothing" do
      assert sorted(InputContract.all_inputs(graph([], []))) == []
      assert InputContract.required_inputs(graph([], [])) == []
    end

    # A mapping source is a dotted reference. A persisted edge holding anything else
    # is malformed — deriving against it must report the gap, since the whole point
    # of this module is to be runnable on a graph that is wrong.
    test "a malformed mapping source is dropped, not raised on" do
      for bad <- [%{"x" => 1}, ["a", "b"], nil] do
        g = graph([step("a"), step("b")], [edge("a", "b", %{"query" => bad})])

        assert sorted(InputContract.all_inputs(g)) == []
        assert sorted(InputContract.missing(g)) == []
        assert InputContract.required_inputs(g) == []
      end
    end

    test "a dropped source leaves a schema-required field reported as unsatisfiable" do
      g =
        graph(
          [
            step("a"),
            step("b", module: "Zaq.Agent.Tools.Workflow.DispatchEvent")
          ],
          [edge("a", "b", %{"event_name" => %{"broken" => true}})]
        )

      assert [%{node: "b", field: "event_name"}] = InputContract.unsatisfiable_inputs(g)
    end

    test "scalar mapping sources other than strings still resolve" do
      g = graph([step("a"), step("b")], [edge("a", "b", %{"query" => :"start.topic"})])

      assert InputContract.optional_inputs(g) == ["topic"]
    end
  end

  # ── Edge conditions and start-fed entry nodes ───────────────────────────────
  #
  # Regression cover for two derivation holes found by auditing `InputContract`
  # against the two real production workflows.

  describe "an edge condition reading `start.*` is a need" do
    # Authoring `start.X` on a condition states that the trigger payload carries
    # `X`, exactly as it does in a mapping or a `{{start.X}}` placeholder. Without
    # this the payload validates clean, the condition evaluates against a field
    # that is not there, the branch prunes, and the run takes the wrong path or
    # ends `incomplete` — no step having failed and nothing naming the field.
    #
    # `EdgeStep` treats an absent reference as nil, so the failure is always
    # silent. Both branches of `generate_company_context` gate on
    # `start.company context content`.
    test "a start-rooted edge condition puts its field in the contract" do
      g =
        graph([step("a"), step("b")], [
          %{
            "from" => "a",
            "to" => "b",
            "mapping" => %{},
            "condition" => %{"field" => "start.tier", "op" => "eq", "value" => "gold"}
          }
        ])

      assert InputContract.required_inputs(g) == ["tier"]
    end

    test "a payload missing a condition's field is not valid" do
      g =
        graph([step("a"), step("b")], [
          %{
            "from" => "a",
            "to" => "b",
            "mapping" => %{},
            "condition" => %{"field" => "start.tier", "op" => "eq", "value" => "gold"}
          }
        ])

      assert %{valid: false, missing_inputs: ["tier"]} = InputContract.check(g, %{})
    end

    test "a condition rooted in a step output is fed, not required" do
      g =
        graph([step("a"), step("b")], [
          %{
            "from" => "a",
            "to" => "b",
            "mapping" => %{},
            "condition" => %{"field" => "a.messages", "op" => "not_empty"}
          }
        ])

      assert InputContract.required_inputs(g) == []
    end
  end

  describe "a condition on a `from: \"start\"` edge always reads the payload" do
    # Nothing has run when a start edge is evaluated: `seed_start_namespace/1`
    # leaves the raw payload at the fact root and the cascade holds only `start`,
    # so every reference such an edge makes resolves to the trigger payload. A
    # bare field there is not step-fed — classifying it `:step` dropped it from
    # both `required_inputs` and `unsatisfiable_inputs`, so the payload validated
    # clean and the branch pruned at run time.
    defp start_edge(condition_field) do
      graph([step("a")], [
        %{
          "from" => "start",
          "to" => "a",
          "mapping" => %{},
          "condition" => %{"field" => condition_field, "op" => "eq", "value" => "gold"}
        }
      ])
    end

    test "a bare field is a payload requirement, not a step output" do
      g = start_edge("tier")

      assert InputContract.required_inputs(g) == ["tier"]
      assert InputContract.unsatisfiable_inputs(g) == []
      assert %{valid: false, missing_inputs: ["tier"]} = InputContract.check(g, %{})
      assert %{valid: true} = InputContract.check(g, %{"tier" => "gold"})
    end

    test "a dotted non-start field is a nested payload path" do
      g = start_edge("user.email")

      assert InputContract.required_inputs(g) == ["user.email"]
      assert InputContract.required_input_shape(g) == %{"user" => %{"email" => nil}}
    end

    test "an explicitly `start.`-prefixed field is unchanged" do
      g = start_edge("start.tier")

      assert InputContract.required_inputs(g) == ["tier"]
    end

    test "a bare field on an ordinary edge is still step-fed" do
      g =
        graph([step("a"), step("b")], [
          %{
            "from" => "a",
            "to" => "b",
            "mapping" => %{},
            "condition" => %{"field" => "tier", "op" => "eq", "value" => "gold"}
          }
        ])

      assert InputContract.required_inputs(g) == []
      assert %{valid: true} = InputContract.check(g, %{})
    end
  end

  describe "contract/2 derives the whole contract in one pass" do
    # `contract/2` reads five fields off a single `needs/1` traversal instead of
    # rebuilding the graph per field. It must stay identical to the piecewise
    # functions — this pins them together so the batch path cannot drift.
    test "every field equals its individually-derived value" do
      g =
        graph(
          [
            step("a"),
            step("b", params: %{"query" => "start.topic"}),
            step("c", params: %{"query" => "nowhere.field"})
          ],
          [
            edge("a", "b", %{"query" => "start.email topic"}),
            edge("b", "c", %{"input" => "start.user.name"}),
            %{
              "from" => "start",
              "to" => "a",
              "mapping" => %{},
              "condition" => %{"field" => "tier", "op" => "eq", "value" => "gold"}
            }
          ]
        )

      payload = %{"email topic" => "hi"}
      contract = InputContract.contract(g, payload)
      verdict = InputContract.check(g, payload)

      assert contract.valid == verdict.valid
      assert contract.missing_inputs == verdict.missing_inputs
      assert contract.required_inputs == InputContract.required_inputs(g)
      assert contract.required_input_shape == InputContract.required_input_shape(g)
      assert contract.unsatisfiable_inputs == InputContract.unsatisfiable_inputs(g)

      # Not a vacuous fixture: it exercises all three kinds at once.
      assert contract.valid == false
      assert "tier" in contract.required_inputs
    end
  end

  describe "a node fed only by `start` is an entry node" do
    # `start` is not a step, so an edge leaving it must not make its target look
    # mid-DAG: the target still reads the trigger payload at the fact root, and its
    # unwritten required fields are `:start`, not `:unknown`.
    #
    # `generate_company_context` has exactly this shape — both
    # `start->craft_email_direct` and `start->extract_company_summary` are real
    # edges in the export.
    @entry_module "Zaq.Agent.Tools.People.EnsurePerson"

    test "an explicit start edge does not change the contract" do
      without_edge = graph([step("entry", module: @entry_module)], [])

      with_edge =
        graph([step("entry", module: @entry_module)], [
          %{"from" => "start", "to" => "entry", "mapping" => %{}}
        ])

      assert InputContract.required_inputs(without_edge) == ["platform"]
      assert InputContract.required_inputs(with_edge) == ["platform"]
    end

    test "a start-fed entry node's required field is traceable, not unknown" do
      g =
        graph([step("entry", module: @entry_module)], [
          %{"from" => "start", "to" => "entry", "mapping" => %{}}
        ])

      assert InputContract.unsatisfiable_inputs(g) == []
    end
  end

  describe "required_input_shape/1" do
    test "a dotted path becomes a nested object, a bare one a null leaf" do
      g = graph([step("a"), step("b")], [edge("a", "b", %{"q" => "start.input.name"})])

      assert InputContract.required_input_shape(g) == %{"input" => %{"name" => nil}}
    end

    test "siblings under one prefix share the object" do
      g =
        graph([step("a"), step("b"), step("c")], [
          edge("a", "b", %{"q" => "start.input.name"}),
          edge("a", "c", %{"q" => "start.input.email"})
        ])

      assert InputContract.required_input_shape(g) == %{
               "input" => %{"email" => nil, "name" => nil}
             }
    end

    test "a key with spaces is a leaf, not a path" do
      g = graph([step("a"), step("b")], [edge("a", "b", %{"q" => "start.email topic"})])

      assert InputContract.required_input_shape(g) == %{"email topic" => nil}
    end

    # The nested form satisfies both readings, so it wins regardless of which
    # path the sort happens to place first.
    test "a path that is both leaf and prefix resolves to the nested form" do
      g =
        graph([step("a"), step("b"), step("c")], [
          edge("a", "b", %{"q" => "start.input"}),
          edge("a", "c", %{"q" => "start.input.name"})
        ])

      assert InputContract.required_input_shape(g) == %{"input" => %{"name" => nil}}
    end

    test "an empty contract is an empty shape" do
      assert InputContract.required_input_shape(graph([], [])) == %{}
    end

    test "filling the shape produces a payload that validates" do
      g =
        graph([step("a"), step("b")], [
          edge("a", "b", %{"q" => "start.email topic", "n" => "start.input.name"})
        ])

      payload = %{"email topic" => "a topic", "input" => %{"name" => "John"}}

      assert Map.keys(InputContract.required_input_shape(g)) |> Enum.sort() ==
               Map.keys(payload) |> Enum.sort()

      assert %{valid: true, missing_inputs: []} = InputContract.check(g, payload)
    end
  end

  # `Batch` is a build-time translator: `DagBuilder.enrich_nodes/1` lowers it into a
  # `map` node whose body sub-steps become real `StepRunner` steps, each with its own
  # module, schema and StepRun row (`"<batch>/<sub>"`). It declares no `schema/0` and
  # no `output_schema/0` of its own, so everything an iteration needs is declared by
  # the body modules — the contract lifts them into the graph and reads them there.
  describe "a Batch node's body sub-steps" do
    @batch "Zaq.Agent.Tools.Workflow.Batch"
    @concat "Zaq.Agent.Tools.Workflow.Concat"
    @dispatch "Zaq.Agent.Tools.Workflow.DispatchEvent"

    defp batch(name, body, params \\ %{}),
      do: %{"name" => name, "module" => @batch, "params" => Map.put(params, "process", body)}

    defp body_node(name, module, params \\ %{}),
      do: %{"name" => name, "type" => "action", "module" => module, "params" => params}

    defp two_step_body,
      do: [body_node("join", @concat), body_node("dispatch", @dispatch)]

    test "Batch itself declares no requirement and no output" do
      # Nothing about the node's own module can stand in for reading its body.
      assert InputContract.required_schema_fields(@batch) == []
      assert InputContract.emitted_schema_fields(@batch) == []
    end

    test "each body sub-step is a node, named as its StepRun is" do
      g =
        graph([batch("batch", two_step_body())], [
          edge("start", "batch", %{"items" => "start.rows"})
        ])

      assert sorted(InputContract.all_inputs(g)) == [
               "batch.items",
               "batch/dispatch.event_name",
               "batch/join.parts"
             ]
    end

    test "the fan-out feeds the first sub-step under its batch field" do
      # `Concat`'s batch field is `parts`, so the chunk arrives there — it is fed by
      # the iteration, not demanded of the payload.
      g =
        graph([batch("batch", two_step_body())], [
          edge("start", "batch", %{"items" => "start.rows"})
        ])

      assert sorted(InputContract.fed_by_steps(g)) == ["batch/join.parts"]
      assert InputContract.required_inputs(g) == ["rows"]
    end

    test "a sub-step's required field no predecessor emits is unsatisfiable" do
      # `dispatch` requires `event_name`. Nothing pins it, the fan-out delivers under
      # `parts`, and `join` emits only result/list/matrix — at run time it reads `nil`
      # and the dispatch goes nowhere. That is the authoring error, not a payload gap.
      g =
        graph([batch("batch", two_step_body())], [
          edge("start", "batch", %{"items" => "start.rows"})
        ])

      assert InputContract.unsatisfiable_inputs(g) == [
               %{node: "batch/dispatch", field: "event_name", source: nil}
             ]
    end

    test "a sub-step's own params satisfy it" do
      body = [
        body_node("join", @concat),
        body_node("dispatch", @dispatch, %{"event_name" => "lead"})
      ]

      g = graph([batch("batch", body)], [edge("start", "batch", %{"items" => "start.rows"})])

      assert InputContract.unsatisfiable_inputs(g) == []
    end

    test "a `{{...}}` in a sub-step is attributed to the sub-step, not to the Batch node" do
      body = [body_node("join", @concat, %{"parts" => ["{{start.language}}"]})]
      g = graph([batch("batch", body)], [edge("start", "batch", %{"items" => "start.rows"})])

      assert InputContract.required_inputs(g) == ["language", "rows"]
      assert MapSet.member?(InputContract.all_inputs(g), "batch/join.parts")
      refute MapSet.member?(InputContract.all_inputs(g), "batch.process")
    end

    # The contract counts a `{{start.X}}` inside a body sub-step as a payload input,
    # which is only honest if the fan-out unit can actually reach the trigger
    # namespace at run time. It can: `MapNodeBuilder.extract_items/6` seeds each unit
    # with the map node's incoming `__cascade__`, so a body step resolves `start.X`
    # exactly like a top-level node. Without that seeding the fork's fact starts
    # empty, `{{start.X}}` collapses to `""`, and this verdict would certify a
    # workflow no payload could ever satisfy. `CascadeReachabilityE2ETest` pins the
    # run-time half through a real run.
    test "a payload feeding a sub-step's `{{start.X}}` checks valid" do
      body = [body_node("join", @concat, %{"parts" => ["{{start.language}}"]})]
      g = graph([batch("batch", body)], [edge("start", "batch", %{"items" => "start.rows"})])

      assert %{valid: true, missing_inputs: []} =
               InputContract.check(g, %{"language" => "fr", "rows" => [1, 2]})
    end

    test "omitting it is missing, named as the payload key the caller must send" do
      body = [body_node("join", @concat, %{"parts" => ["{{start.language}}"]})]
      g = graph([batch("batch", body)], [edge("start", "batch", %{"items" => "start.rows"})])

      assert %{valid: false, missing_inputs: ["language"], supplied: ["rows"]} =
               InputContract.check(g, %{"rows" => [1, 2]})
    end

    test "a `post_process` sub-step's `{{start.X}}` is a payload input too" do
      # `post_process` specs run inside the same fork as the body, off the same
      # seeded unit, so they reach `start` on the same terms.
      body = [body_node("join", @concat)]

      params = %{
        "post_process" => [body_node("dispatch", @dispatch, %{"event_name" => "{{start.topic}}"})]
      }

      g =
        graph([batch("batch", body, params)], [edge("start", "batch", %{"items" => "start.rows"})])

      assert InputContract.required_inputs(g) == ["rows", "topic"]

      assert %{valid: true, missing_inputs: []} =
               InputContract.check(g, %{"topic" => "leads", "rows" => [1]})
    end

    test "`post_process` continues the same chain" do
      body = [body_node("join", @concat)]
      params = %{"post_process" => [body_node("dispatch", @dispatch)]}

      g =
        graph([batch("batch", body, params)], [edge("start", "batch", %{"items" => "start.rows"})])

      assert InputContract.unsatisfiable_inputs(g) == [
               %{node: "batch/dispatch", field: "event_name", source: nil}
             ]
    end

    test "the iterated collection is a need of the Batch node itself" do
      # `Batch` reads `items` off the incoming fact but declares it nowhere. Fed only
      # by `start`, it is a payload requirement; fed by nothing at all, an error.
      g =
        graph([batch("batch", two_step_body())], [edge("start", "batch", %{"other" => "start.x"})])

      assert "items" in InputContract.required_inputs(g)

      orphan = graph([step("a"), batch("batch", two_step_body())], [edge("a", "batch")])

      assert %{node: "batch", field: "items", source: nil} in InputContract.unsatisfiable_inputs(
               orphan
             )
    end
  end
end

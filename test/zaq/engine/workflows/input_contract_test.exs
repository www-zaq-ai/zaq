defmodule Zaq.Engine.Workflows.InputContractTest do
  use ExUnit.Case, async: true

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
      assert InputContract.required_inputs(g) == ["email topic"]
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
      assert InputContract.required_inputs(g) == ["email topic"]
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

    test "a Condition resolves a bare dotted input against the cascade" do
      g =
        graph(
          [
            step("a"),
            step("b",
              module: "Zaq.Agent.Tools.Workflow.Condition",
              params: %{"input" => "a.metadata"}
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
                "input" => "a.metadata",
                "conditions" => [%{"key" => "total.last_message_date", "op" => "gte"}]
              }
            )
          ],
          [edge("a", "b")]
        )

      # `Condition` evaluates each key against the *resolved input* — here
      # `a.metadata` — with `__cascade__` merged in. `total` is a key of that value,
      # so it is run-time data the graph says nothing about, not an input.
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
                "input" => "a.metadata",
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

    test "a Condition key rooted at a node or at start is still a reference" do
      g =
        graph(
          [
            step("a"),
            step("b",
              module: "Zaq.Agent.Tools.Workflow.Condition",
              params: %{
                "input" => "a.metadata",
                "conditions" => [
                  %{"key" => "a.messages", "value" => 1},
                  %{"key" => "start.sequence", "value" => 4}
                ]
              }
            )
          ],
          [edge("a", "b")]
        )

      # Only these two roots reach past the input value into the cascade.
      assert sorted(InputContract.all_inputs(g)) == ["b.conditions", "b.input"]
      assert InputContract.required_inputs(g) == ["sequence"]
    end

    test "a Condition input reading start is required from the payload" do
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

      assert InputContract.required_inputs(g) == ["plan", "tier"]
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

    # Pending, with `condition_test.exs`: `@condition_module` is the only module name
    # left in `InputContract`, and it exists solely because `Condition` resolves bare
    # references the uniform `{{...}}` scan cannot see. This FAILS today and passes
    # once those params migrate to `{{...}}` and the special case is deleted.
    @tag :skip
    test "a bare dotted Condition param needs no module-specific knowledge (pending)" do
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
      # exactly the way the contract exists to catch.
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

    test "a key present but nil counts as supplied" do
      assert %{valid: true} = InputContract.check(["topic"], %{"topic" => nil})
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
end

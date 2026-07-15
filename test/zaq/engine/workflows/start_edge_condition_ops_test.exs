defmodule Zaq.Engine.Workflows.StartEdgeConditionOpsTest do
  @moduledoc """
  Validates every `EdgeCondition` operator when it routes from the reserved
  `start` origin and reads the trigger payload through a `start.<field>` dotted
  path — the pattern a lead-enrichment entry fork uses to branch on a spaced key
  like `start.company context content`.

  A `from: "start"` edge that guards/maps becomes a ROOT `EdgeStep` that
  transforms the planted initial fact (see `DagBuilder.add_edge/6`). The trigger
  payload is seeded into `__cascade__.start` by
  `WorkflowRunAgent.seed_start_namespace/1`, so `FactLookup` resolves
  `start.<field>` (including keys with spaces) cascade-first.

  Each scenario is driven end-to-end through the real dispatch path
  (`TriggerNode.fire → Workflows.create_and_start_run → WorkflowRunAgent`): a
  `%Zaq.Event{}` carries the payload in its `request`, `TriggerNode` plants it
  under `assigns.input`, and a single `from: "start"` guard routes to an
  `OkAction` node named `matched`. When the guard passes, `matched` runs; when it
  fails, `ConditionNotMet` prunes it and no `matched` StepRun exists.

  The `empty` / `not_empty` block additionally covers the present / blank /
  *absent* content cases against a spaced key, since that is where a
  content-vs-generate entry fork branches.
  """
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Workflows.DagBuilder

  alias Zaq.Engine.{TriggerNode, Workflows}
  alias Zaq.Engine.Workflows.Test.{UseCaseFixtures, UseCaseStubs}
  alias Zaq.Event

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  @trigger_event "engine:start"
  @ok_module "Zaq.Engine.Workflows.Test.OkAction"

  # Creates a workflow whose single `matched` node is reachable only through a
  # `from: "start"` guard carrying `condition`, binds it to the trigger, and fires
  # a real event whose `request` becomes the planted trigger payload. Returns the run.
  defp fire_with_guard(condition, request) do
    nodes = [%{name: "matched", type: "action", module: @ok_module, params: %{}, index: 0}]
    edges = [%{from: "start", to: "matched", condition: condition}]

    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "Start Edge Op #{System.unique_integer([:positive])}",
        status: "active",
        nodes: nodes,
        edges: edges
      })

    {:ok, trigger} = Workflows.create_trigger(%{event_name: @trigger_event, enabled: true})
    {:ok, _} = Workflows.assign_workflow_to_trigger(trigger, workflow)

    event = %Event{
      request: request,
      next_hop: nil,
      name: :start,
      trace_id: Ecto.UUID.generate(),
      assigns: %{}
    }

    :ok = TriggerNode.fire(@trigger_event, event)

    workflow.id |> Workflows.list_runs() |> List.first()
  end

  defp matched?(run) do
    run.id
    |> Workflows.list_step_runs()
    |> Enum.any?(&(&1.step_name == "matched" and &1.status == "completed"))
  end

  # Builds a value-less condition map (for `empty` / `not_empty`) with string keys,
  # mirroring the persisted workflow shape. Value-bearing ops use inline literals.
  defp cnd(field, op), do: %{"field" => field, "op" => op}

  # {label, condition, request, expected_match?} for every value-bearing operator,
  # each with a passing and a failing case, all reading through `start.<field>`.
  # Conditions are inline literals (module attributes can't call local functions).
  @value_cases [
    {"eq true", %{"field" => "start.status", "op" => "eq", "value" => "active"},
     %{"status" => "active"}, true},
    {"eq false", %{"field" => "start.status", "op" => "eq", "value" => "active"},
     %{"status" => "inactive"}, false},
    {"neq true", %{"field" => "start.status", "op" => "neq", "value" => "active"},
     %{"status" => "inactive"}, true},
    {"neq false", %{"field" => "start.status", "op" => "neq", "value" => "active"},
     %{"status" => "active"}, false},
    {"gt true", %{"field" => "start.score", "op" => "gt", "value" => 5}, %{"score" => 10}, true},
    {"gt false", %{"field" => "start.score", "op" => "gt", "value" => 20}, %{"score" => 10},
     false},
    {"lt true", %{"field" => "start.score", "op" => "lt", "value" => 20}, %{"score" => 10}, true},
    {"lt false", %{"field" => "start.score", "op" => "lt", "value" => 5}, %{"score" => 10},
     false},
    {"gte true (boundary)", %{"field" => "start.score", "op" => "gte", "value" => 10},
     %{"score" => 10}, true},
    {"gte false", %{"field" => "start.score", "op" => "gte", "value" => 11}, %{"score" => 10},
     false},
    {"lte true (boundary)", %{"field" => "start.score", "op" => "lte", "value" => 10},
     %{"score" => 10}, true},
    {"lte false", %{"field" => "start.score", "op" => "lte", "value" => 9}, %{"score" => 10},
     false},
    {"in true", %{"field" => "start.role", "op" => "in", "value" => ["admin", "owner"]},
     %{"role" => "admin"}, true},
    {"in false", %{"field" => "start.role", "op" => "in", "value" => ["admin", "owner"]},
     %{"role" => "guest"}, false}
  ]

  describe "value-bearing operators route from start.<field>" do
    for {label, condition, request, expected} <- @value_cases do
      test "#{label}" do
        run = fire_with_guard(unquote(Macro.escape(condition)), unquote(Macro.escape(request)))

        # A passing guard runs `matched` (the sole leaf) → completed; a failing
        # guard prunes it, so no terminal step completes → incomplete.
        assert run.status == unquote(if expected, do: "completed", else: "incomplete")
        assert matched?(run) == unquote(expected)
      end
    end
  end

  # The entry-fork field: a downcased header WITH SPACES read as
  # `start.company context content`. Present → not_empty; "" or absent → empty.
  @spaced_field "start.company context content"

  describe "empty / not_empty on a spaced start.<field> (GenerateCompanyContext fork)" do
    test "not_empty matches when the content is present" do
      run =
        fire_with_guard(cnd(@spaced_field, "not_empty"), %{"company context content" => "# Doc"})

      assert run.status == "completed"
      assert matched?(run)
    end

    test "not_empty is pruned when the content is a blank string" do
      run = fire_with_guard(cnd(@spaced_field, "not_empty"), %{"company context content" => ""})
      # Sole leaf `matched` pruned → no terminal step completed → incomplete.
      assert run.status == "incomplete"
      refute matched?(run)
    end

    test "not_empty is pruned when the field is absent entirely" do
      run = fire_with_guard(cnd(@spaced_field, "not_empty"), %{"row_index" => 5})
      assert run.status == "incomplete"
      refute matched?(run)
    end

    test "empty matches when the content is a blank string" do
      run = fire_with_guard(cnd(@spaced_field, "empty"), %{"company context content" => ""})
      assert run.status == "completed"
      assert matched?(run)
    end

    test "empty matches when the field is absent entirely" do
      run = fire_with_guard(cnd(@spaced_field, "empty"), %{"row_index" => 5})
      assert run.status == "completed"
      assert matched?(run)
    end

    test "empty is pruned when the content is present" do
      run = fire_with_guard(cnd(@spaced_field, "empty"), %{"company context content" => "# Doc"})
      # Sole leaf `matched` pruned → no terminal step completed → incomplete.
      assert run.status == "incomplete"
      refute matched?(run)
    end
  end

  describe "entry fork on a spaced start.<field> with a realistic lead row" do
    # Fires the REAL Generate Company Context workflow — imported from its JSON
    # export — through the dispatch path and returns the run plus a
    # step_name => status map. The entry fork branches on `start.company context
    # content` (`not_empty` → craft_email_direct, `empty` → extract_company_summary),
    # so the edge-guard StepRun names (`start__to__<to>__edge`) read the routing
    # decision. Downstream external boundaries (LLM agents, the sheet write, and the
    # DispatchEvent leaves) are stubbed; the entry edge-guard StepRuns are written at
    # entry regardless of what happens downstream.
    defp fire_real_lead(request) do
      {:ok, workflow} =
        UseCaseFixtures.import_fixture("generate_company_context.json",
          swap: %{
            "extract_company_summary" => UseCaseStubs.AgentStub,
            "map_business_to_zaq" => UseCaseStubs.AgentStub,
            "produce_email_topic" => UseCaseStubs.AgentStub,
            "craft_email_direct" => UseCaseStubs.BridgeDispatchEvent,
            "craft_email" => UseCaseStubs.BridgeDispatchEvent,
            "update_sheet_row" => UseCaseStubs.UpdateSheetStub
          }
        )

      # TriggerNode plants the trigger payload under assigns.input; replicate that
      # shape and drive the run directly so any error surfaces here.
      source_event = %Event{
        request: request,
        next_hop: nil,
        name: :lead_identified,
        trace_id: Ecto.UUID.generate(),
        assigns: %{input: request}
      }

      {:ok, run} = Workflows.create_and_start_run(workflow, source_event)
      {run, run.id |> Workflows.list_step_runs() |> Map.new(&{&1.step_name, &1.status})}
    end

    test "a populated 'company context content' cell short-circuits to craft_email (spaced key works)" do
      # The payload key EXACTLY matches the guard field (`start.company context
      # content`). This proves the edge condition resolves a SPACED key end-to-end
      # through the real module — no snake_case required.
      {_run, by_name} =
        fire_real_lead(%{
          "company official name" => "Acme Corp",
          "company website" => "https://acme.com",
          "company context content" => "## Company Summary\n\nAcme builds rockets.",
          "row_index" => 5
        })

      assert by_name["start__to__craft_email_direct__edge"] == "completed",
             "not_empty on a spaced start.<field> must pass and short-circuit to craft_email"

      assert by_name["start__to__extract_company_summary__edge"] == "skipped",
             "the empty branch must be skipped when context already exists"

      refute Map.has_key?(by_name, "extract_company_summary"),
             "workflow must NOT regenerate when context already exists"
    end

    # The engine's FactLookup canonicalizes keys (case + space/underscore/hyphen +
    # trim), so a guard field written as `company context content` resolves a
    # header stored in any of these equivalent forms — no action changes needed.
    for {label, header_key} <- [
          {"snake_case header", "company_context_content"},
          {"Title Case header", "Company Context Content"},
          {"trailing-space header", "company context content "},
          {"hyphenated header", "company-context-content"}
        ] do
      test "a populated #{label} still short-circuits (engine canonicalizes keys)" do
        {_run, by_name} =
          fire_real_lead(%{
            "company official name" => "Acme Corp",
            unquote(header_key) => "## Company Summary\n\nAcme builds rockets.",
            "row_index" => 5
          })

        assert by_name["start__to__craft_email_direct__edge"] == "completed",
               "normalized match must let not_empty resolve #{unquote(header_key)}"

        refute Map.has_key?(by_name, "extract_company_summary"),
               "must not regenerate when an equivalently-formatted context cell is present"
      end
    end

    test "a genuinely different word ('company context file') still does NOT match" do
      # Normalization bridges FORMATTING, not different words: `file` != `content`,
      # so this correctly stays on the generate branch (no false positive).
      {_run, by_name} =
        fire_real_lead(%{
          "company official name" => "Acme Corp",
          "company context file" => "## Company Summary\n\nAcme builds rockets.",
          "row_index" => 5
        })

      assert by_name["start__to__craft_email_direct__edge"] == "skipped",
             "a different word must not fuzzy-match into the not_empty branch"

      assert by_name["start__to__extract_company_summary__edge"] == "completed"
    end
  end

  describe "the two complementary start edges are mutually exclusive" do
    # Replicates the content-vs-generate entry fork exactly: two `from: "start"`
    # edges on the same field, one `not_empty` → `have_context`, one `empty` →
    # `generate`. Exactly one branch must run for any given payload.
    defp fire_fork(request) do
      nodes = [
        %{name: "have_context", type: "action", module: @ok_module, params: %{}, index: 0},
        %{name: "generate", type: "action", module: @ok_module, params: %{}, index: 1}
      ]

      edges = [
        %{from: "start", to: "have_context", condition: cnd(@spaced_field, "not_empty")},
        %{from: "start", to: "generate", condition: cnd(@spaced_field, "empty")}
      ]

      {:ok, workflow} =
        Workflows.create_workflow(%{
          name: "Start Fork #{System.unique_integer([:positive])}",
          status: "active",
          nodes: nodes,
          edges: edges
        })

      {:ok, trigger} = Workflows.create_trigger(%{event_name: @trigger_event, enabled: true})
      {:ok, _} = Workflows.assign_workflow_to_trigger(trigger, workflow)

      event = %Event{
        request: request,
        next_hop: nil,
        name: :start,
        trace_id: Ecto.UUID.generate(),
        assigns: %{}
      }

      :ok = TriggerNode.fire(@trigger_event, event)

      run = workflow.id |> Workflows.list_runs() |> List.first()
      by_name = run.id |> Workflows.list_step_runs() |> Map.new(&{&1.step_name, &1.status})
      {run, by_name}
    end

    test "present content takes have_context and prunes generate" do
      {run, by_name} = fire_fork(%{"company context content" => "# Doc"})
      assert run.status == "completed"
      assert by_name["have_context"] == "completed"
      refute Map.get(by_name, "generate") == "completed"
    end

    test "blank content takes generate and prunes have_context" do
      {run, by_name} = fire_fork(%{"company context content" => ""})
      assert run.status == "completed"
      assert by_name["generate"] == "completed"
      refute Map.get(by_name, "have_context") == "completed"
    end

    test "absent field takes generate and prunes have_context" do
      {run, by_name} = fire_fork(%{"row_index" => 5})
      assert run.status == "completed"
      assert by_name["generate"] == "completed"
      refute Map.get(by_name, "have_context") == "completed"
    end
  end

  describe "edge guards are built non-retriable (max_retries: 0)" do
    test "the DagBuilder wires every EdgeStep node with max_retries: 0" do
      # An EdgeStep "fails" only by raising ConditionNotMet to prune a branch —
      # deterministic control flow. Retrying it re-evaluates the same pure
      # condition, wasting Jido's default backoff (250ms) per pruned branch, so
      # guards must be non-retriable like StepRunner.
      steps = %{
        "nodes" => [
          %{
            "name" => "matched",
            "type" => "action",
            "module" => @ok_module,
            "params" => %{},
            "index" => 0
          }
        ],
        "edges" => [
          %{
            "from" => "start",
            "to" => "matched",
            "condition" => %{"field" => "start.ctx", "op" => "not_empty"}
          }
        ]
      }

      assert {:ok, workflow} = DagBuilder.build(steps)

      edge_nodes =
        workflow.graph.vertices
        |> Map.values()
        |> Enum.filter(&(Map.get(&1, :action_mod) == Zaq.Engine.Workflows.Steps.EdgeStep))

      assert edge_nodes != [], "expected at least one EdgeStep guard node in the built DAG"

      for node <- edge_nodes do
        assert Keyword.get(node.exec_opts, :max_retries) == 0,
               "edge guards must be built with max_retries: 0 so a pruned branch never retries"
      end
    end
  end
end

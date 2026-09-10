defmodule Zaq.Engine.Workflows.CascadeReachabilityE2ETest do
  @moduledoc """
  Adversarial probes against the claim argued on PR #696 — *"similar data from a
  later step does not override the previous data, and all of it stays accessible
  by scoping with the step's node key (`NodeA.name` and `NodeB.name` are both
  reachable)"*.

  Each test asks the real run — `WorkflowRunAgent` → `StepRunner`, nothing
  stubbed — whether a shape can be built where that stops being true.
  """
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.InputContract
  alias Zaq.Engine.Workflows.Step
  alias Zaq.Engine.Workflows.Workflow
  alias Zaq.Engine.Workflows.WorkflowRunAgent

  @echo "Zaq.Engine.Workflows.Test.EchoResolved"
  @tag_mod "Zaq.Engine.Workflows.Test.EmitTag"
  @partial_x "Zaq.Engine.Workflows.Test.EmitPartialX"
  @noop "Zaq.Engine.Workflows.Test.Noop"

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  defp create_workflow(nodes, edges) do
    Workflows.create_workflow(%{
      name: "CascadeReach #{System.unique_integer()}",
      status: "active",
      nodes: nodes,
      edges: edges
    })
  end

  # `map` is not in the node-type inclusion list the public changeset enforces, so
  # a map workflow is inserted as a struct — the same route `map_node_test` takes.
  defp insert_workflow(nodes, edges) do
    Zaq.Repo.insert!(%Workflow{
      name: "CascadeReach #{System.unique_integer([:positive])}",
      status: "active",
      nodes: Enum.map(nodes, &struct(Step.Node, &1)),
      edges: Enum.map(edges, &struct(Step.Edge, &1))
    })
  end

  defp run_struct_workflow(nodes, edges, payload),
    do: nodes |> insert_workflow(edges) |> start(payload)

  defp run_workflow(nodes, edges, payload) do
    {:ok, wf} = create_workflow(nodes, edges)
    start(wf, payload)
  end

  defp start(wf, payload) do
    {:ok, run} =
      Workflows.create_run(wf, %{
        "request" => nil,
        "assigns" => %{"trigger_type" => "manual", "input" => payload},
        "trace_id" => Ecto.UUID.generate()
      })

    {:ok, finished} = WorkflowRunAgent.execute(run)
    {finished, Workflows.list_step_runs(run.id)}
  end

  defp seen_all(step_runs, step_name) do
    step_runs
    |> Enum.filter(&(&1.step_name == step_name))
    |> Enum.map(fn sr ->
      sr.results |> Zaq.MapUtils.fetch_either(:seen, "seen")
    end)
  end

  defp echo_node(name, index, params),
    do: %{name: name, type: "action", module: @echo, params: params, index: index}

  describe "convergence — a node with two predecessors" do
    test "is refused at workflow creation, so the shape can never exist at run time" do
      nodes = [
        %{name: "root", type: "action", module: @noop, params: %{}, index: 0},
        %{name: "a", type: "action", module: @tag_mod, params: %{"tag" => "A"}, index: 1},
        %{name: "b", type: "action", module: @tag_mod, params: %{"tag" => "B"}, index: 2},
        echo_node("probe", 3, %{
          "from_node" => "{{a.tag}}",
          "unqualified" => "{{b.tag}}",
          "from_start" => "{{start.seed}}"
        })
      ]

      edges = [
        %{from: "root", to: "a"},
        %{from: "root", to: "b"},
        %{from: "a", to: "probe"},
        %{from: "b", to: "probe"}
      ]

      # A fan-in node receives one fact, so it could only ever carry one branch's
      # cascade — `{{a.tag}}` and `{{b.tag}}` could not both resolve. The graph
      # validator refuses the shape outright rather than leaving it to run time.
      assert {:error, changeset} = create_workflow(nodes, edges)

      assert {"invalid workflow composition", [reason: {:convergence_not_supported, ["probe"]}]} =
               changeset.errors[:nodes]
    end
  end

  describe "shallow root merge — an upstream node shadowing a nested trigger key" do
    test "the sibling key the node did not emit is gone from the root" do
      nodes = [
        %{name: "a", type: "action", module: @partial_x, params: %{}, index: 0},
        echo_node("probe", 1, %{
          "unqualified" => "{{x.a}}",
          "from_start" => "{{start.x.a}}",
          "from_node" => "{{x.b}}"
        })
      ]

      {finished, step_runs} =
        run_workflow(nodes, [%{from: "a", to: "probe"}], %{"x" => %{"a" => 1, "b" => 2}})

      assert finished.status == "completed"
      [seen] = seen_all(step_runs, "probe")

      # `a` emitted only `x.b`, so the whole `x` was replaced: root `x.a` is lost.
      # A lone `{{...}}` that resolves to nothing is `nil` — there is no string for it
      # to be interpolated into, so `""` would be a value invented for a reference
      # that found none.
      assert Zaq.MapUtils.fetch_either(seen, :unqualified, "unqualified") == nil
      # …but the node-qualified path still resolves it.
      assert Zaq.MapUtils.fetch_either(seen, :from_start, "from_start") == 1
      assert Zaq.MapUtils.fetch_either(seen, :from_node, "from_node") == 3
    end
  end

  describe "a node literally named `start`" do
    test "is refused, so nothing can shadow the trigger namespace" do
      nodes = [
        %{name: "start", type: "action", module: @tag_mod, params: %{"tag" => "NODE"}, index: 0},
        echo_node("probe", 1, %{"from_start" => "{{start.tag}}"})
      ]

      # `FactLookup` resolves a cascade step by atom before string, so a node
      # keyed "start" would silently lose to the `:start` trigger entry. The name
      # is reserved instead.
      assert {:error, changeset} = create_workflow(nodes, [%{from: "start", to: "probe"}])

      [node_changeset | _] = changeset.changes.nodes

      assert {"is reserved and cannot be used as a node name", []} =
               node_changeset.errors[:name]
    end
  end

  describe "inside a map fork — where the convergence guard does not reach" do
    # `MapNodeBuilder.build_fork_spec/4` documents that a body node "resolves its
    # `{{...}}` exactly like a top-level one" because it goes through the same
    # `DagBuilder.wrapper_params/5`. But the fan-out unit is a bare stamped item
    # (`stamp_item/2`) carrying no `__cascade__`, so a fork's fact starts empty:
    # `{{start.*}}` and `{{upstream.*}}` collapse to "" instead of resolving.
    test "a body step still reaches the trigger namespace and the map's source node" do
      nodes = [
        %{
          name: "emit",
          type: "action",
          module: "Zaq.Engine.Workflows.Test.EmitItems",
          params: %{},
          index: 0
        },
        %{
          name: "m",
          type: "map",
          params: %{
            "over" => "items",
            "body" => [
              %{
                "name" => "probe",
                "type" => "action",
                "module" => @echo,
                "params" => %{
                  "from_start" => "{{start.seed}}",
                  "from_node" => "{{emit.items}}",
                  "unqualified" => "{{n}}"
                }
              }
            ]
          },
          index: 1
        }
      ]

      {finished, step_runs} =
        run_struct_workflow(nodes, [%{from: "emit", to: "m"}], %{"seed" => "S"})

      assert finished.status == "completed"

      forks =
        step_runs
        |> Enum.filter(&String.starts_with?(&1.step_name, "m/probe"))
        |> Enum.map(&Zaq.MapUtils.fetch_either(&1.results, :seen, "seen"))

      assert length(forks) == 3

      for seen <- forks do
        # Currently "" for both — the fork's cascade holds only the fork itself.
        assert Zaq.MapUtils.fetch_either(seen, :from_start, "from_start") == "S"
        assert Zaq.MapUtils.fetch_either(seen, :from_node, "from_node") != ""
      end

      # each fork saw its own item, not a shared one
      assert forks
             |> Enum.map(&Zaq.MapUtils.fetch_either(&1, :unqualified, "unqualified"))
             |> Enum.sort() == [1, 2, 3]
    end
  end

  # The contract exists so a `valid` verdict means the run will not fail for want of
  # input. A mapping naming a node on another branch used to pass that test silently:
  # the node is in the graph, so the source read as step-fed — but the cascade is
  # built per path, so the fact arriving here never carried it.
  describe "a mapping naming a node the run never passes through" do
    defp cross_branch_workflow do
      nodes = [
        %{name: "root", type: "action", module: @noop, params: %{}, index: 0},
        %{name: "sibling", type: "action", module: @tag_mod, params: %{"tag" => "T"}, index: 1},
        %{
          name: "consumer",
          type: "action",
          module: "Zaq.Agent.Tools.Workflow.Concat",
          params: %{},
          index: 2
        }
      ]

      edges = [
        %{from: "root", to: "sibling"},
        %{from: "root", to: "consumer", mapping: %{"parts" => "sibling.tag"}}
      ]

      {:ok, wf} = create_workflow(nodes, edges)
      wf
    end

    # No convergence, acyclic, connected — `Composition.validate/2` accepts it, so the
    # shape reaches the contract as a stored workflow rather than only as a raw map.
    test "the shape saves, and the run fails on the field the mapping did not deliver" do
      {finished, step_runs} = start(cross_branch_workflow(), %{})

      assert finished.status == "failed"

      assert Enum.any?(step_runs, &(&1.step_name == "consumer" and &1.status == "failed"))
    end

    # The contract cannot ask the payload for `parts`: no value a caller sends reaches a
    # field the graph wires from a node this run never visits. Catching the authoring
    # error itself is workflow validation's job, at save time.
    test "the contract asks the payload for nothing" do
      wf = cross_branch_workflow()

      assert InputContract.required_inputs(wf) == []
      assert InputContract.optional_inputs(wf) == []
    end
  end

  # `InputContract.param_needs/3` drops a `{{...}}` under a key an incoming edge also
  # targets, on the grounds that the mapped value wins and the reference is never
  # looked up. That is a claim about the merge order, so a real run makes it.
  describe "a param holding a placeholder under a key the edge also maps" do
    defp overwritten_param_workflow do
      nodes = [
        %{
          name: "a",
          type: "action",
          module: @tag_mod,
          params: %{"tag" => "FROM_MAPPING"},
          index: 0
        },
        echo_node("probe", 1, %{"text" => "{{start.topic}}"})
      ]

      edges = [%{from: "a", to: "probe", mapping: %{"text" => "a.tag"}}]

      {:ok, wf} = create_workflow(nodes, edges)
      wf
    end

    defp probe_text(step_runs) do
      step_runs
      |> Enum.find(&(&1.step_name == "probe"))
      |> then(&Zaq.MapUtils.fetch_either(&1.results, :seen, "seen"))
      |> Zaq.MapUtils.fetch_either(:text, "text")
    end

    test "the mapped value wins, even when the payload carries the reference's path" do
      {_finished, step_runs} = start(overwritten_param_workflow(), %{"topic" => "FROM_PAYLOAD"})

      assert probe_text(step_runs) == "FROM_MAPPING"
    end

    # So the payload owes nothing here: omitting the path changes neither the value the
    # action sees nor whether the run completes.
    test "and it still wins when the payload carries nothing" do
      {finished, step_runs} = start(overwritten_param_workflow(), %{})

      assert finished.status == "completed"
      assert probe_text(step_runs) == "FROM_MAPPING"
    end
  end

  # `schema_needs/4` treats a node with no incoming edge as an entry node. For a
  # workflow authored without a `start` edge that is the root, and it really does read
  # the trigger payload — so this is correct, not the `Enum.all?([], _)` accident it
  # resembles. A node with no edges at all cannot be saved
  # (`Composition.check_connectivity/1`), so there is no other case.
  describe "a root node with no incoming edge" do
    test "reads its required fields straight from the trigger payload" do
      nodes = [
        %{
          name: "join",
          type: "action",
          module: "Zaq.Agent.Tools.Workflow.Concat",
          params: %{},
          index: 0
        },
        %{name: "tail", type: "action", module: @noop, params: %{}, index: 1}
      ]

      {:ok, wf} = create_workflow(nodes, [%{from: "join", to: "tail"}])

      assert InputContract.required_inputs(wf) == ["parts"]

      {finished, step_runs} = start(wf, %{"parts" => ["a", "b"]})

      assert finished.status == "completed"

      assert Enum.find(step_runs, &(&1.step_name == "join")).results
             |> Zaq.MapUtils.fetch_either(:result, "result") == "ab"
    end
  end
end

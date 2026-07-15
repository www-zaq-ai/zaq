defmodule Zaq.Engine.Workflows.Test.UseCaseFixtures do
  @moduledoc """
  Workflow fixtures for engine tests.

  Two flavours:

    * **Full use-case workflows** — real workflow JSON exported from the BO, stored
      under `test/support/fixtures/workflows/*.json` and loaded via `import_fixture/2`
      through the production `Workflows.import_workflow/1` path. These drive the
      *complete* multi-node pipelines end-to-end (Batch, Condition, Concat, HITL,
      Increment, …); only the true external boundaries (LLM, Sheets, SMTP) are
      swapped for stubs via the `:swap` option.

    * **Minimal purpose-built DAGs** — the smallest DAG that exercises one specific
      engine invariant (`trivial_consumer/1`, etc.), for fast, focused seam guards.

  The engine, trigger, import, edge-mapping, and persistence code paths these
  fixtures run through stay 100% real.
  """

  alias Zaq.Engine.Workflows

  @noop_module "Zaq.Engine.Workflows.Test.Noop"

  @fixtures_dir Path.join(__DIR__, "fixtures/workflows")

  @doc """
  Loads an exported workflow JSON fixture and imports it through the production
  `Workflows.import_workflow/1` path, returning `{:ok, workflow}`.

  Options:

    * `:swap` — a `%{"node_name" => StubModule}` map. Before import, each named
      node's `"module"` is replaced with the stub, so only true external boundaries
      (LLM/Sheets/SMTP) are stubbed while every other node stays the real production
      module. Descends into `Batch` nodes' nested `"process"` / `"post_process"`
      pipelines so leaves inside an iteration can be swapped too.
    * `:patch` — a `%{"node_name" => (node -> node)}` map of arbitrary per-node
      transforms applied after the module swaps (e.g. shorten a sleep duration).
  """
  @spec import_fixture(String.t(), keyword()) ::
          {:ok, Workflows.Workflow.t()} | {:error, term()}
  def import_fixture(filename, opts \\ []) do
    swaps = Keyword.get(opts, :swap, %{})
    patches = Keyword.get(opts, :patch, %{})

    @fixtures_dir
    |> Path.join(filename)
    |> File.read!()
    |> Jason.decode!()
    |> update_in(["nodes"], fn nodes ->
      Enum.map(nodes || [], &transform_node(&1, swaps, patches))
    end)
    |> Workflows.import_workflow()
  end

  # Swap a node's module and/or apply an arbitrary patch (both by node name),
  # recursing into Batch `process` / `post_process` pipelines so nested leaves are
  # reachable too.
  defp transform_node(node, swaps, patches) do
    node =
      case Map.get(swaps, node["name"]) do
        nil -> node
        mod -> Map.put(node, "module", inspect(mod))
      end

    node =
      case Map.get(patches, node["name"]) do
        fun when is_function(fun, 1) -> fun.(node)
        _ -> node
      end

    case node["params"] do
      %{} = params ->
        params =
          params
          |> transform_pipeline("process", swaps, patches)
          |> transform_pipeline("post_process", swaps, patches)

        Map.put(node, "params", params)

      _ ->
        node
    end
  end

  defp transform_pipeline(params, key, swaps, patches) do
    case params[key] do
      list when is_list(list) ->
        Map.put(params, key, Enum.map(list, &transform_node(&1, swaps, patches)))

      _ ->
        params
    end
  end

  @doc """
  Creates a workflow from `workflow_params`, creates a trigger from
  `trigger_attrs`, and binds the two in a single transaction. Returns
  `{:ok, workflow}`.

  Public-API glue for building a workflow bound to a trigger in one transaction.
  """
  @spec create_workflow_with_trigger(map(), map()) ::
          {:ok, Workflows.Workflow.t()} | {:error, term()}
  def create_workflow_with_trigger(workflow_params, trigger_attrs) do
    Zaq.Repo.transaction(fn ->
      {:ok, workflow} = Workflows.create_workflow(workflow_params)
      {:ok, trigger} = Workflows.create_trigger(trigger_attrs)
      {:ok, _} = Workflows.assign_workflow_to_trigger(trigger, workflow)
      workflow
    end)
  end

  @doc """
  A trivial single-node workflow whose only purpose is to be wired to a trigger,
  so trigger-firing / run-creation can be asserted. The node does nothing.
  """
  @spec trivial_consumer(keyword()) :: map()
  def trivial_consumer(opts \\ []) do
    %{
      name: Keyword.get(opts, :name, "Trigger Consumer"),
      status: "active",
      nodes: [
        %{name: "start_node", type: "action", module: @noop_module, params: %{}, index: 0}
      ],
      edges: []
    }
  end
end

defmodule Zaq.Engine.Workflows.Step.Node do
  @moduledoc """
  Embedded schema for a single node in a workflow DAG.

  Stored as a JSONB array in the `nodes` column of `workflows`.
  Validated at changeset time so malformed steps are rejected before they
  reach `DagBuilder` at run time.

  Node types:
  - `"action"` / `"agent"` — requires `module`
  - `"workflow"` — references another workflow by id via
    `params["workflow_ref"]`; its steps are spliced inline at run creation by
    `Zaq.Engine.Workflows.Composition`
  - `"map"` — a general iteration primitive: runs an inline `params["body"]`
    pipeline once per item of the upstream collection named by `params["over"]`,
    fanning out via Runic `FanOut`/`FanIn`. Body nodes may themselves be
    `action`/`agent`/`workflow`. Batch is a consumer built on top of this; it is
    not a Batch-specific construct.

  Conditional routing is handled by edge attributes (`condition`, `mapping`), not by
  a dedicated node type. See `Step.Edge` and `DagBuilder` for the edge-based routing
  mechanism.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Engine.Workflows.Action

  @primary_key false

  @types ~w(action agent workflow map)

  embedded_schema do
    field :name, :string
    field :type, :string
    field :module, :string
    field :index, :integer
    field :params, :map, default: %{}
  end

  def types, do: @types

  def changeset(node, attrs) do
    node
    |> cast(attrs, [:name, :type, :module, :index, :params])
    |> validate_required([:name, :type, :index])
    |> validate_inclusion(:type, @types)
    |> validate_module_required_for_action()
    |> validate_module_contract()
    |> validate_workflow_ref_required()
    |> validate_map_params()
  end

  defp validate_module_required_for_action(changeset) do
    type = get_field(changeset, :type)
    module = get_field(changeset, :module)

    if type in ["action", "agent"] && (is_nil(module) || module == "") do
      add_error(changeset, :module, "is required for action/agent nodes")
    else
      changeset
    end
  end

  # Save-time module-contract enforcement: an action/agent node's `module` must
  # resolve to a compiled module satisfying the `Workflows.Action` contract, so
  # an unrunnable workflow is rejected at save
  # rather than failing only when a run is attempted. Skipped when the module is
  # blank (already flagged by `validate_module_required_for_action/1`) so the same
  # node does not collect two errors.
  defp validate_module_contract(changeset) do
    type = get_field(changeset, :type)
    module = get_field(changeset, :module)

    case node_module_error(type, module) do
      nil -> changeset
      msg -> add_error(changeset, :module, msg)
    end
  end

  # Returns nil when the (type, module) pair satisfies the contract, otherwise a
  # human-readable error. Only `action`/`agent` nodes carry a module contract;
  # blank modules return nil here (requiredness is validated elsewhere).
  defp node_module_error(type, module) when type in ["action", "agent"] do
    if is_nil(module) or module == "" do
      nil
    else
      case Action.resolve(module) do
        {:error, {:unknown_module, _}} ->
          "could not be resolved to a loaded module"

        {:ok, mod} ->
          translator_or_contract_error(mod)
      end
    end
  end

  defp node_module_error(_type, _module), do: nil

  # Orchestrator/translator nodes (e.g. `Batch`) implement the `Workflows.Node`
  # behaviour (`enrich/2`) and are lowered to another node type by `DagBuilder`
  # before execution; they are deliberately not `Workflows.Action` modules, so
  # the action contract does not apply to them. Every other action/agent module
  # must satisfy the contract at save time.
  defp translator_or_contract_error(mod) do
    if function_exported?(mod, :enrich, 2) do
      nil
    else
      case Action.validate(mod) do
        :ok ->
          nil

        {:error, {:contract_violation, _mod, missing}} ->
          "does not satisfy the Action contract (missing: " <>
            Enum.map_join(missing, ", ", &to_string/1) <> ")"
      end
    end
  end

  # A `"workflow"` reference node points at another workflow by id under
  # `params["workflow_ref"]` (see `Composition`).
  defp validate_workflow_ref_required(changeset) do
    type = get_field(changeset, :type)
    ref = changeset |> get_field(:params) |> Kernel.||(%{}) |> Map.get("workflow_ref")

    if type == "workflow" && (is_nil(ref) || ref == "") do
      add_error(changeset, :params, "workflow_ref is required for workflow nodes")
    else
      changeset
    end
  end

  # A `"map"` node iterates an inline `body` pipeline over the upstream collection
  # named by `over` (see `DagBuilder`/`Composition`). `over` + `body` are required.
  # Optional throughput/delivery knobs (the Batch superset):
  #   - `chunk_size` — positive integer; nil ⇒ per-item fan-out
  #   - `delivery`   — "item" | "list" (how each unit reaches the body via `field`)
  #   - `field`      — the param key under which the unit is delivered
  defp validate_map_params(changeset) do
    if get_field(changeset, :type) == "map" do
      params = changeset |> get_field(:params) |> Kernel.||(%{})

      changeset
      |> validate_map_over(Map.get(params, "over"))
      |> validate_map_body(Map.get(params, "body"))
      |> validate_map_delivery(Map.get(params, "delivery"))
      |> validate_map_chunk_size(Map.get(params, "chunk_size"))
      |> validate_map_max_items(Map.get(params, "max_items"))
    else
      changeset
    end
  end

  defp validate_map_over(changeset, over) when is_binary(over) and over != "", do: changeset

  defp validate_map_over(changeset, _over),
    do: add_error(changeset, :params, "over is required for map nodes")

  defp validate_map_body(changeset, [_ | _] = body) do
    body
    |> Enum.with_index()
    |> Enum.reduce(changeset, fn {bnode, i}, cs ->
      case body_node_error(bnode) do
        nil -> cs
        msg -> add_error(cs, :params, "body node #{i} #{msg}")
      end
    end)
  end

  defp validate_map_body(changeset, _body),
    do: add_error(changeset, :params, "body must list at least one node for map nodes")

  # Body nodes (string-keyed maps) are validated for type validity, module
  # requiredness, and the Action contract — the same save-time guarantees a
  # top-level node gets, so a `map` whose body names a missing/non-conforming
  # module is rejected at save. Body nodes carry no `index` (it is assigned at
  # build), so full node requiredness is intentionally not re-run here.
  defp body_node_error(bnode) when is_map(bnode) do
    type = body_field(bnode, "type")
    module = body_field(bnode, "module")

    cond do
      type not in @types ->
        "has invalid type #{inspect(type)}"

      type in ["action", "agent"] and (is_nil(module) or module == "") ->
        "is missing its module"

      true ->
        case node_module_error(type, module) do
          nil -> nil
          msg -> "module #{msg}"
        end
    end
  end

  defp body_node_error(_bnode), do: "must be a map"

  # Body nodes are normally string-keyed (JSONB / serialized snapshots); tolerate
  # atom keys too. `:type`/`:module` are existing schema-field atoms, so resolving
  # them with `to_existing_atom` never creates new atoms.
  defp body_field(bnode, key) do
    Map.get(bnode, key) || Map.get(bnode, String.to_existing_atom(key))
  end

  defp validate_map_delivery(changeset, nil), do: changeset
  defp validate_map_delivery(changeset, d) when d in ["item", "list"], do: changeset

  defp validate_map_delivery(changeset, _d),
    do: add_error(changeset, :params, ~s(delivery must be "item" or "list"))

  defp validate_map_chunk_size(changeset, nil), do: changeset
  defp validate_map_chunk_size(changeset, n) when is_integer(n) and n > 0, do: changeset

  defp validate_map_chunk_size(changeset, _n),
    do: add_error(changeset, :params, "chunk_size must be a positive integer")

  # `max_items` caps the fan-out cardinality. Optional at save; when present
  # it must be a positive integer. The run-time backstop lives in `DagBuilder`.
  defp validate_map_max_items(changeset, nil), do: changeset
  defp validate_map_max_items(changeset, n) when is_integer(n) and n > 0, do: changeset

  defp validate_map_max_items(changeset, _n),
    do: add_error(changeset, :params, "max_items must be a positive integer")
end

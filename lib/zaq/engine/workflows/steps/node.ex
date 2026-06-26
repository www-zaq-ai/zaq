defmodule Zaq.Engine.Workflows.Step.Node do
  @moduledoc """
  Embedded schema for a single node in a workflow DAG.

  Stored as a JSONB array in the `nodes` column of `workflows`.
  Validated at changeset time so malformed steps are rejected before they
  reach `DagBuilder` at run time.

  Node types (the **authorable** surface):
  - `"action"` / `"agent"` — requires `module`
  - `"workflow"` — references another workflow by id via
    `params["workflow_ref"]`; its steps are spliced inline at run creation by
    `Zaq.Engine.Workflows.Composition`

  Iteration (fan-out/fan-in) is **not** a node type users author. It is an internal
  lowering target (`map`) produced at build time by a translator's
  `c:Zaq.Engine.Workflows.Node.enrich/2` callback — today the `Zaq.Agent.Tools.Workflow.Batch`
  action. Authors express iteration as a `type: "action"` Batch node; `map` never
  appears in persisted, authored steps. The same rule holds for any future
  orchestration primitive: it ships as an `action` tool that enriches onto an
  internal node type, so the authoring surface stays `action`/`agent`/`workflow`.

  ## Module-level (`Node`) validation

  Beyond the per-type checks below, `changeset/2` dispatches to the node module's
  optional `c:Zaq.Engine.Workflows.Node.validate/1` callback (the save-time analogue
  of `DagBuilder`'s build-time enrich dispatch). A translator like `Batch` validates its
  own inline sub-pipeline there, so the persisted representation is guaranteed
  runnable without `Step.Node` knowing the translator's internals.

  Conditional routing is handled by edge attributes (`condition`, `mapping`), not by
  a dedicated node type. See `Step.Edge` and `DagBuilder` for the edge-based routing
  mechanism.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Engine.Workflows.Action

  @primary_key false

  @types ~w(action agent workflow)

  # Names reserved for virtual edge sentinels (see `DagBuilder.start_sentinel/0`).
  # A real node may not take one of these names, or a `from: "start"` edge could
  # not be told apart from an edge out of a real node.
  @reserved_node_names ~w(start)

  embedded_schema do
    field :name, :string
    field :type, :string
    field :module, :string
    field :index, :integer
    field :params, :map, default: %{}
  end

  def types, do: @types

  def reserved_node_names, do: @reserved_node_names

  def changeset(node, attrs) do
    node
    |> cast(attrs, [:name, :type, :module, :index, :params])
    |> validate_required([:name, :type, :index])
    |> validate_inclusion(:type, @types)
    |> validate_name_not_reserved()
    |> validate_module_required_for_action()
    |> validate_module_contract()
    |> validate_workflow_ref_required()
    |> validate_node_module()
  end

  # A node may not take a reserved sentinel name (e.g. "start"), case-insensitively.
  defp validate_name_not_reserved(changeset) do
    case get_field(changeset, :name) do
      name when is_binary(name) ->
        if String.downcase(String.trim(name)) in @reserved_node_names do
          add_error(changeset, :name, "is reserved and cannot be used as a node name")
        else
          changeset
        end

      _ ->
        changeset
    end
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

  # Dispatches to the node module's optional `Workflows.Node.validate/1` callback —
  # the save-time analogue of `DagBuilder`'s `enrich/2` dispatch. A translator
  # (e.g. `Batch`) validates its own inline sub-pipeline there, so `Step.Node` never
  # needs to know a translator's internals. Modules that do not implement the
  # callback (plain action/agent/workflow nodes) are left untouched.
  defp validate_node_module(changeset) do
    module = get_field(changeset, :module)

    with {:ok, mod} <- resolve_node_module(module),
         true <- function_exported?(mod, :validate, 1),
         {:error, reason} <- mod.validate(node_attrs(changeset)) do
      add_error(changeset, :params, node_validation_message(reason))
    else
      _ -> changeset
    end
  end

  defp resolve_node_module(module) when is_binary(module) and module != "",
    do: Action.resolve(module)

  defp resolve_node_module(_module), do: :error

  # Reconstructs the string-keyed node map the `Node.validate/1` callback expects
  # (mirrors the persisted JSONB shape).
  defp node_attrs(changeset) do
    %{
      "name" => get_field(changeset, :name),
      "type" => get_field(changeset, :type),
      "module" => get_field(changeset, :module),
      "index" => get_field(changeset, :index),
      "params" => get_field(changeset, :params) || %{}
    }
  end

  defp node_validation_message(reason) when is_binary(reason), do: reason
  defp node_validation_message(reason), do: inspect(reason)

  @doc """
  Validates a single node map (string-keyed, JSONB shape), returning `:ok` or
  `{:error, message}`.

  This is the **one** place node validity is defined. A top-level node is validated
  by `changeset/2`; an inline sub-pipeline node owned by a translator (e.g. the
  `process`/`post_process` nodes of a `Batch`) is validated by routing it through
  this function — which simply runs the same `changeset/2`. Translators must not
  re-derive type/module/contract checks of their own; they call this so node rules
  live in a single home and a nested translator node is even validated recursively.

  Inline body nodes carry no `index` (it is assigned at build), so a placeholder is
  supplied to satisfy requiredness.
  """
  @spec validate_node_map(map()) :: :ok | {:error, String.t()}
  def validate_node_map(attrs) when is_map(attrs) do
    changeset = changeset(%__MODULE__{}, Map.put_new(attrs, "index", 0))

    if changeset.valid? do
      :ok
    else
      {:error, errors_to_message(changeset)}
    end
  end

  defp errors_to_message(%Ecto.Changeset{errors: errors}) do
    Enum.map_join(errors, "; ", fn {field, {msg, _opts}} -> "#{field} #{msg}" end)
  end
end

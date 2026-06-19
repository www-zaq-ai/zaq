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
  # named by `over` (see `DagBuilder`/`Composition`). Both are required, and `body`
  # must list at least one inline node to run per item.
  defp validate_map_params(changeset) do
    if get_field(changeset, :type) == "map" do
      params = changeset |> get_field(:params) |> Kernel.||(%{})
      over = Map.get(params, "over")
      body = Map.get(params, "body")

      changeset
      |> validate_map_over(over)
      |> validate_map_body(body)
    else
      changeset
    end
  end

  defp validate_map_over(changeset, over) when is_binary(over) and over != "", do: changeset

  defp validate_map_over(changeset, _over),
    do: add_error(changeset, :params, "over is required for map nodes")

  defp validate_map_body(changeset, [_ | _]), do: changeset

  defp validate_map_body(changeset, _body),
    do: add_error(changeset, :params, "body must list at least one node for map nodes")
end

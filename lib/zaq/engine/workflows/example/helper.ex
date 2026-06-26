defmodule Zaq.Engine.Workflows.UseCases.Helper do
  @moduledoc """
  Shared helpers for the example workflow use cases (`Zaq.Engine.Workflows.UseCases.*`).

  These examples are temporary scaffolding and are expected to be removed once the
  real authoring surface lands — keep shared example-only logic here (not in the
  `Zaq.Engine.Workflows` context) so it can be deleted in one go.
  """

  alias Zaq.Engine.Workflows

  @doc """
  Creates a workflow from `workflow_params`, creates a trigger from
  `trigger_attrs`, and binds the two — all in a single transaction. Returns
  `{:ok, workflow}`.

  The use-case modules differ only in their workflow params and trigger
  attributes, so they all route through here.
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
end

defmodule Zaq.Agent.Tools.Workflow.ValidateWorkflowInput do
  @moduledoc """
  Workflow action: pre-flight check that a candidate event input carries
  everything a workflow's steps need.

  Answers one question: *if this payload were dispatched now, would every step
  have the data it needs?* The contract is derived from the graph — every input
  every node needs, minus the inputs an upstream step feeds
  (`Zaq.Engine.Workflows.InputContract`) — and the candidate payload is resolved
  against it through `Zaq.Engine.Workflows.FactLookup`, so a key matches exactly
  the way it will at run time.

  An agent loops on the result: read `missing_inputs`, fill the gaps, call again,
  and dispatch once `valid` is true. The gaps are filled into
  `required_input_shape` — a dotted path is a shape, not a key, and an agent
  handed only the flat list reliably sends `"input.name"` as a literal key, which
  `FactLookup` cannot resolve.

  The action never returns `{:error, _}` for a failing verdict — that would prune
  the downstream subgraph and make it impossible to route a bad payload to a
  remediation branch. A `valid: false` result is `{:ok, _}` so an edge condition
  on `valid` can send the run to `HumanInTheLoop` or back to the agent.
  `{:error, _}` is reserved for a workflow that cannot be read at all.

  ## Coverage

  `unknown_inputs` names `"node.field"` inputs whose provenance the graph does not
  state — a mid-DAG node's required field with no mapping, no param reference, and
  no pinned default reads its predecessor's output at the fact root, which cannot
  be traced statically. A `valid: true` verdict does not cover those, so an empty
  `unknown_inputs` is what makes it complete.
  """

  use Zaq.Engine.Workflows.Action,
    name: "validate_workflow_input",
    description: """
    Check whether a candidate event input satisfies every step of a workflow
    before dispatching it.

    A path in `required_inputs` / `missing_inputs` is a shape, not a key: a dot
    means nesting, so `input.name` is `{"input": {"name": ...}}` and never a flat
    key literally called `"input.name"`. Build the payload from
    `required_input_shape`, which is that structure already assembled with null
    leaves — fill in the values and send it back.
    """,
    schema:
      Zoi.object(%{
        workflow_id:
          Zoi.string(description: "Id of the workflow the input is intended to trigger"),
        # `Zoi.any()` — a candidate trigger payload is string-keyed (it arrives
        # from an LLM tool call or another workflow's DispatchEvent), and a
        # scalar payload must be reportable as invalid rather than rejected at
        # schema validation.
        #
        # `Zoi.optional/1` after the default is what makes the field optional:
        # `Zoi.default/2` alone leaves `meta.required` true, and
        # `InputContract.required_schema_fields/1` reads exactly that — so
        # without it this action would contribute a phantom required `input` to
        # the contract of every workflow that uses it as a node.
        input:
          Zoi.any(description: "Candidate event input to check against the workflow's steps")
          |> Zoi.default(%{})
          |> Zoi.optional()
      }),
    output_schema:
      Zoi.object(%{
        valid:
          Zoi.boolean(
            description: "True when the input satisfies every field the workflow's steps need"
          ),
        input: Zoi.any(description: "The candidate input, echoed back unchanged"),
        missing_inputs:
          Zoi.array(Zoi.string(),
            description: "Payload paths the input does not supply — fill these and retry"
          ),
        required_inputs:
          Zoi.array(Zoi.string(),
            description: "Every payload path the workflow reads from the trigger event"
          ),
        required_input_shape:
          Zoi.map(
            description:
              "`required_inputs` as the payload itself — a nested skeleton with null leaves. " <>
                "Fill in the values and send this; do not send a dotted path as a flat key."
          ),
        unknown_inputs:
          Zoi.array(Zoi.string(),
            description:
              "`node.field` inputs whose provenance the graph does not state — not covered by the verdict"
          )
      })

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.InputContract

  @impl Jido.Action
  def run(%{workflow_id: workflow_id} = params, _context) do
    input = Map.get(params, :input) || %{}

    case fetch_workflow(workflow_id) do
      {:ok, workflow} ->
        verdict = InputContract.check(workflow, input)

        {:ok,
         %{
           valid: verdict.valid,
           input: input,
           missing_inputs: verdict.missing_inputs,
           required_inputs: InputContract.required_inputs(workflow),
           required_input_shape: InputContract.required_input_shape(workflow),
           unknown_inputs: InputContract.unknown_inputs(workflow)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The id arrives from an LLM tool call, so it is cast before it reaches the
  # query — a non-uuid string would otherwise raise `Ecto.Query.CastError`
  # instead of returning a correctable error to the agent.
  defp fetch_workflow(workflow_id) do
    with {:ok, id} <- cast_id(workflow_id),
         %{} = workflow <- Workflows.get_workflow(id) do
      {:ok, workflow}
    else
      nil -> {:error, "workflow not found: #{inspect(workflow_id)}"}
      :error -> {:error, "workflow_id is not a valid uuid: #{inspect(workflow_id)}"}
    end
  end

  defp cast_id(workflow_id) when is_binary(workflow_id), do: Ecto.UUID.cast(workflow_id)
  defp cast_id(_workflow_id), do: :error
end

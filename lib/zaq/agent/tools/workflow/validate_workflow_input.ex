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

  Filling a gap means sending a value. `required_input_shape` is a skeleton with
  null leaves, and a required path present but null is reported missing exactly
  like an absent one — otherwise the loop could converge on the skeleton itself
  and dispatch a payload the run reads as `nil`. `false`, `0` and `""` are values
  an agent can mean, and they satisfy their path.

  `invalid_inputs` is the other half of a failing verdict: the path was supplied,
  but with a kind of value the step's schema refuses — `"42"` where an integer is
  declared. Its remediation is a different *kind* of value, not another value, so
  it is reported apart from `missing_inputs` and each entry names what was expected
  and what arrived. A path is type-checked only where the payload value reaches a
  schema-declared field whole; where it does not, the check stays presence-only.

  The action never returns `{:error, _}` for a failing verdict — that would prune
  the downstream subgraph and make it impossible to route a bad payload to a
  remediation branch. A `valid: false` result is `{:ok, _}` so an edge condition
  on `valid` can send the run to `HumanInTheLoop` or back to the agent.
  `{:error, _}` is reserved for a workflow that cannot be read at all.

  ## Coverage

  `unsatisfiable_inputs` names the fields no step can feed and no payload can
  supply — nothing local writes them, no predecessor's `output_schema` declares
  them, and they are not rooted in `start`. That is a broken graph, not a payload
  gap: the run reads `nil` and fails silently, and no input the agent sends can
  fix it. A `valid: true` verdict does not cover those, so an empty
  `unsatisfiable_inputs` is what makes it complete.

  The action is agent-callable, so it may execute on the Agent node. Both the
  workflow read and the derivation are delegated to the Engine through
  `NodeRouter.dispatch/1` (`:workflow_input_contract`); only the derived contract
  crosses back.
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
    leaves — fill in the values and send it back. A leaf left null counts as
    missing, so sending the skeleton back unchanged is never valid, and a value of
    the wrong kind is reported in `invalid_inputs` rather than accepted.
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
            description:
              "True when the input supplies a non-null value for every field the " <>
                "workflow's steps need"
          ),
        input: Zoi.any(description: "The candidate input, echoed back unchanged"),
        missing_inputs:
          Zoi.array(Zoi.string(),
            description:
              "Payload paths the input does not supply — absent, or present with a null " <>
                "value. Fill these with real values and retry"
          ),
        required_inputs:
          Zoi.array(Zoi.string(),
            description: "Every payload path the workflow reads from the trigger event"
          ),
        invalid_inputs:
          Zoi.array(Zoi.map([]),
            description:
              "Paths supplied with the wrong kind of value, as `{path, expected, got}` — " <>
                "send a value of the expected kind. Distinct from `missing_inputs`: the " <>
                "path was supplied, it is the kind that is wrong."
          ),
        required_input_shape:
          Zoi.map(
            description:
              "`required_inputs` as the payload itself — a nested skeleton with null leaves. " <>
                "Fill in the values and send this; do not send a dotted path as a flat key, " <>
                "and do not send it back with leaves still null — a null leaf is a gap."
          ),
        unsatisfiable_inputs:
          Zoi.array(Zoi.map([]),
            description:
              "Fields no step feeds and no payload can supply, as `{node, field, source}` — " <>
                "`source` is the dangling reference, null when the graph names none. A broken " <>
                "graph, not a payload gap: fix the workflow, do not retry with a bigger input."
          )
      })

  alias Zaq.Event
  alias Zaq.NodeRouter

  @impl Jido.Action
  def run(params, context) do
    # Params reach an action atom-keyed from `DagBuilder`, but string-keyed from a
    # direct tool call, so both forms are read — and a params map carrying neither is
    # a caller error to report, not a `FunctionClauseError` to crash the step with.
    case fetch_param(params, :workflow_id) do
      {:ok, workflow_id} -> validate(workflow_id, params, context)
      :error -> {:error, "workflow_id is required"}
    end
  end

  defp validate(workflow_id, params, context) do
    # Default only the *omitted* key: `false`, `0` and `""` are payloads an agent
    # can send, and the contract must report them invalid rather than silently
    # replace them with an empty map and echo that back.
    input =
      case fetch_param(params, :input) do
        {:ok, input} -> input
        :error -> %{}
      end

    node_router = Map.get(context, :node_router, NodeRouter)

    case derive_contract(node_router, workflow_id, input) do
      {:ok, contract} when is_map(contract) ->
        {:ok, Map.put(contract, :input, input)}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, "Unexpected workflow contract response: #{inspect(other)}"}
    end
  end

  defp fetch_param(params, key) do
    with :error <- Map.fetch(params, key) do
      Map.fetch(params, Atom.to_string(key))
    end
  end

  # The tool is agent-callable, so it may run on the Agent node while the
  # workflow lives on the Engine. Dispatching a named Engine action keeps both
  # the read and the derivation on the Engine node; only the contract map
  # crosses back.
  defp derive_contract(node_router, workflow_id, input) do
    %{workflow_id: workflow_id, input: input}
    |> Event.new(:engine, opts: [action: :workflow_input_contract])
    |> node_router.dispatch()
    |> Map.fetch!(:response)
  end
end

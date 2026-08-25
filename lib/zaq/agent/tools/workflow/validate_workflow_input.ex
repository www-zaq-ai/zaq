defmodule Zaq.Agent.Tools.Workflow.ValidateWorkflowInput do
  @moduledoc """
  Workflow action: checks a candidate event input against a workflow's steps
  before it is dispatched.

  The contract is derived from the graph — every input every node needs, minus the
  inputs an upstream step feeds (`Zaq.Engine.Workflows.InputContract`) — and the
  payload is resolved against it through `Zaq.Engine.Workflows.FactLookup`, so a
  key matches exactly the way it will at run time. The verdict names what is
  absent (`missing_inputs`), what is wrong-kinded (`invalid_inputs`) and what the
  graph itself cannot satisfy (`unsatisfiable_inputs`), and carries the payload to
  build (`required_input_shape`) and the declared type of every path
  (`input_types`) as fields rather than as prose — a map cannot be truncated into
  something that still reads as an answer, and a sentence carrying a contract was.

  An input is required: `%{}`, `nil` and an omitted key are refused with
  `{:error, "input is required"}` before the workflow is read. `false`, `0` and
  `""` are payloads a caller can mean, and are judged like any other.

  A failing verdict is `{:ok, %{valid: false}}`, never `{:error, _}` — an error
  prunes the downstream subgraph, and a bad payload has to stay routable to a
  remediation branch. `{:error, _}` is for the calls that produce no verdict at
  all: an unreadable workflow, and no input to judge.

  Agent-callable, so it may run on the Agent node: both the workflow read and the
  derivation are delegated to the Engine through `NodeRouter.dispatch/1`
  (`:workflow_input_contract`), and only the contract crosses back.
  """

  use Zaq.Engine.Workflows.Action,
    name: "validate_workflow_input",
    description: """
    Check whether a candidate event input satisfies every step of a workflow
    before dispatching it.

    `input` is required: send the payload you mean to dispatch. `{}` and null are
    refused rather than answered — there is no verdict on a payload you did not
    send. Ask the user for the values you do not have; never invent one, and never
    show a placeholder payload with made-up values or types in place of asking.

    The verdict names every unsupplied path in `missing_inputs` and every
    wrong-kinded one in `invalid_inputs`, and gives `required_input_shape` to fill
    and `input_types` to fill it correctly. Fill the gaps and call again until
    `valid` is true.

    `required_inputs` must all be supplied. `optional_inputs` may be omitted, but
    anything sent for one is type-checked like the rest — never invent a value to
    fill one in.

    `input_types` gives the declared kind of every path in both lists and is the
    only source of types: one guessed from a field's name is wrong as often as it
    is right, and an example payload built from a guess is one the workflow
    rejects. A path listed as `any` is untyped — say `any` rather than narrowing
    it.

    A path is a shape, not a key: a dot means nesting, so `input.name` is
    `{"input": {"name": ...}}` and never a flat key literally called
    `"input.name"`. Build the payload from `required_input_shape`, that structure
    already assembled with null leaves. A leaf left null counts as missing, so
    sending the skeleton back unchanged is never valid.
    """,
    schema:
      Zoi.object(%{
        workflow_id:
          Zoi.string(description: "Id of the workflow the input is intended to trigger"),
        input:
          Zoi.any(
            description:
              "The event payload you intend to dispatch to this workflow. Must be " <>
                "non-empty: `{}` and null are refused"
          )
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
            description:
              "Every payload path the workflow reads from the trigger event and cannot " <>
                "run without"
          ),
        input_types:
          Zoi.map(
            description:
              "The declared kind of every path in `required_inputs` and " <>
                "`optional_inputs`, as `{path: kind}`. This is the ONLY source of " <>
                "types: state a type for a path only if it appears here, and never " <>
                "guess one from the path's name. A path whose kind is `any` is " <>
                "genuinely untyped — say `any`, do not invent something narrower."
          ),
        optional_inputs:
          Zoi.array(Zoi.string(),
            description:
              "Payload paths the workflow reads but whose fields its steps declare " <>
                "optional. Leaving one out is valid; sending one of the wrong kind is " <>
                "not, and is reported in `invalid_inputs`. Do not invent values for " <>
                "these — send one only if the user gave it."
          ),
        invalid_inputs:
          Zoi.array(Zoi.map([]),
            description:
              "Paths supplied with a value the step refuses, as " <>
                "`{path, expected, got, message}` — send a value of the expected kind. " <>
                "Distinct from `missing_inputs`: the path was supplied, it is the value " <>
                "that is wrong. When the failure is inside a nested value, `expected` and " <>
                "`got` are both the outer kind and `message` names the offending key — " <>
                "read `message` first."
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

  # An empty input carries nothing to judge, so it is refused before the workflow
  # is read. `false`, `0` and `""` are payloads an agent can mean and go through:
  # the contract reports them invalid rather than silently replacing them.
  defp validate(workflow_id, params, context) do
    case fetch_param(params, :input) do
      {:ok, input} when input != %{} and not is_nil(input) ->
        judge(workflow_id, input, context)

      _empty ->
        {:error, "input is required"}
    end
  end

  defp judge(workflow_id, input, context) do
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

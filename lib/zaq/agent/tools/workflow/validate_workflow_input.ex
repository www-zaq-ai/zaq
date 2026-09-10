defmodule Zaq.Agent.Tools.Workflow.ValidateWorkflowInput do
  @moduledoc """
  Workflow action: judges a candidate event input against a workflow's steps
  before it is dispatched.

  The contract is derived from the graph — every input every node needs, minus the
  inputs an upstream step feeds (`Zaq.Engine.Workflows.InputContract`) — and the
  payload is resolved against it through `Zaq.Engine.Workflows.FactLookup`, so a key
  matches exactly the way it will at run time.

  The verdict is two fields: `valid?`, and one `errors` entry per problem carrying
  everything about it — the `path` to fix, a machine-readable `code`, and a sentence.
  Nothing has to be cross-referenced against anything else, and there is no
  payload-shaped object in the response for a caller to echo back as an answer.

  It judges the payload, never the graph. A workflow whose own wiring is broken is an
  authoring error for workflow validation to catch at save time, not something a
  caller can fix by sending different values. Describing what a workflow *can* be sent
  is a different question again, and not this tool's.

  An input is required: `%{}`, `nil` and an omitted key are refused with
  `{:error, "input is required"}` before the workflow is read. `false`, `0` and
  `""` are payloads a caller can mean, and are judged like any other.

  A failing verdict is `{:ok, %{valid?: false}}`, never `{:error, _}` — an error
  prunes the downstream subgraph, and a bad payload has to stay routable to a
  remediation branch. `{:error, _}` is for the calls that produce no verdict at
  all: an unreadable workflow, and no input to judge.

  Agent-callable, so it may run on the Agent node: both the workflow read and the
  derivation are delegated to the Engine through `NodeRouter.dispatch/1`
  (`:workflow_input_contract`), and only the verdict crosses back.
  """

  use Zaq.Engine.Workflows.Action,
    name: "validate_workflow_input",
    description: """
    Check whether a candidate event input satisfies every step of a workflow
    before dispatching it.

    `input` is required: send the payload you mean to dispatch. `{}` and null are
    refused rather than answered — there is no verdict on a payload you did not
    send. Ask the user for the values you do not have; never invent one.

    When `valid?` is false, `errors` has one entry per problem. Fix every entry and
    call again. `code` says what kind of problem it is: `required` means the value
    was not supplied — ask the user for it; `invalid_type` means send a different
    kind of value; anything else is a rule the value broke, and `message` names it.

    `path` is a list of keys to walk, not a name. `["input", "name"]` means
    `{"input": {"name": ...}}`. `["rows", 0, "email"]` means the `email` key of the
    first element of `rows`. Never join a path with dots and send it as one key.
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
        valid?:
          Zoi.boolean(
            description:
              "True when every path the workflow's steps need is supplied with a value " <>
                "they accept. Equivalent to `errors` being empty"
          ),
        errors:
          Zoi.array(Zoi.map([]),
            description:
              "One entry per problem, as `{path, code, message, expected}`. `path` is " <>
                "the list of keys to walk into the payload — never join it with dots. " <>
                "`code` is `required` (not supplied — ask the user), `invalid_type` " <>
                "(send a different kind of value), or a rule the value broke, which " <>
                "`message` names. `expected` is JSON Schema for that path: it carries " <>
                "the type AND the rules (minLength, maximum, pattern, enum, and a " <>
                "nested object's properties), so state what a field accepts from it and " <>
                ~s|never guess from the field's name. `{"type": "any"}` means the | <>
                "workflow declares no type there — say so rather than inventing one. " <>
                "Fix every entry and call again."
          )
      })

  alias Zaq.Engine.Workflows.Action
  alias Zaq.Event
  alias Zaq.NodeRouter

  @impl Jido.Action
  def run(params, context) do
    # A params map naming no workflow is a caller error to report, not a
    # `FunctionClauseError` to crash the step with.
    case Action.fetch_param(params, :workflow_id) do
      {:ok, workflow_id} -> validate(workflow_id, params, context)
      :error -> {:error, "workflow_id is required"}
    end
  end

  # An empty input carries nothing to judge, so it is refused before the workflow
  # is read. `false`, `0` and `""` are payloads an agent can mean and go through:
  # the contract reports them invalid rather than silently replacing them.
  defp validate(workflow_id, params, context) do
    case Action.fetch_param(params, :input) do
      {:ok, input} when input != %{} and not is_nil(input) ->
        judge(workflow_id, input, context)

      _empty ->
        {:error, "input is required"}
    end
  end

  defp judge(workflow_id, input, context) do
    node_router = Map.get(context, :node_router, NodeRouter)

    case derive_contract(node_router, workflow_id, input) do
      {:ok, verdict} when is_map(verdict) ->
        {:ok, verdict}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, "Unexpected workflow contract response: #{inspect(other)}"}
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

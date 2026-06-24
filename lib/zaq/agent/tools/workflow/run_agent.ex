defmodule Zaq.Agent.Tools.Workflow.RunAgent do
  @moduledoc """
  Runs a named configured agent with template-variable substitution.

  Substitutes `{{variable}}` placeholders in `input` using all accumulated
  workflow params, then dispatches to the agent node.

  The configured agent owns its system prompt and model. All run-specific/custom
  data belongs in `input` (the user message), never in a prompt override.

  ## Schema

  - `agent_name` — required. Name of the configured agent in the DB.
  - `input`      — required. The user message / task prompt (supports `{{variable}}`).

  All other params in the accumulated workflow state are available as
  `{{variable_name}}` substitutions in `input`.

  ## Example

      RunAgent.run(
        %{agent_name: "LeadOutreach", input: "Draft email for {{name}} at {{company}}",
          name: "John", company: "Acme"},
        %{run_id: "run-123"}
      )
      # => {:ok, %{output: "Hi John..."}}
  """

  use Zaq.Engine.Workflows.Action,
    name: "run_agent",
    description: "Run a named configured agent with template-variable substitution.",
    schema: [
      agent_name: [type: :string, required: true, doc: "Name of the agent in the DB."],
      input: [
        type: :string,
        required: true,
        doc: "Task/user message. Supports {{variable}} substitution."
      ]
    ],
    output_schema: [
      output: [type: :string, required: true, doc: "Agent response text."]
    ]

  require Logger

  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Event
  alias Zaq.NodeRouter

  @impl Jido.Action
  def run(%{agent_name: agent_name, input: input} = params, context) do
    dispatch_agent_run(agent_name, input, params, context)
  end

  defp dispatch_agent_run(agent_name, input, params, context) do
    node_router = Map.get(context, :node_router, NodeRouter)
    vars = build_vars(params)
    resolved_input = substitute(input, vars)
    run_id = Map.get(context, :run_id) || Map.get(context, "run_id")

    # provider: nil keeps this a node-internal request — the agent node's
    # `:run_pipeline` handler runs its pre-run verification (identity, prompt
    # guard, scoping) and returns the %Outgoing{} directly instead of routing it
    # to a delivery channel.
    incoming = %Incoming{
      content: resolved_input,
      channel_id: "workflow:#{run_id || "anon"}",
      author_id: "workflow",
      provider: nil
    }

    incoming
    |> build_event(agent_name)
    |> node_router.dispatch()
    |> Map.get(:response)
    |> handle_response()
  end

  defp build_event(incoming, agent_name) do
    incoming
    |> Event.new(:agent,
      opts: [
        action: :run_pipeline,
        pipeline_opts: [skip_permissions: true]
      ]
    )
    |> Map.put(:assigns, %{agent_selection: %{agent_name: agent_name}})
  end

  defp handle_response(%Outgoing{} = outgoing) do
    if error_metadata?(outgoing.metadata) do
      reason = outgoing.metadata[:reason] || "unknown"
      {:error, "agent_failed:#{reason}"}
    else
      {:ok, %{output: outgoing.body}}
    end
  end

  defp handle_response({:error, reason}), do: {:error, "agent_failed:#{inspect(reason)}"}
  defp handle_response(other), do: {:error, "agent_failed:#{inspect(other)}"}

  defp error_metadata?(metadata), do: is_map(metadata) and metadata[:error]

  # Build substitution vars from all params except the action-level ones.
  #
  # Nested maps (e.g. `row` as set by EnsurePerson) are spread one level deep
  # so their keys become top-level {{variable}} substitutions. Flat keys always
  # win over keys that came from a nested map. Internal workflow keys
  # (__cascade__) are excluded entirely.
  defp build_vars(params) do
    dropped =
      Map.drop(params, [:agent_name, :input, :__cascade__, "__cascade__"])

    nested_vars =
      dropped
      |> Enum.flat_map(fn
        {_k, v} when is_map(v) ->
          Enum.map(v, fn {nk, nv} -> {to_string(nk), to_string_safe(nv)} end)

        _ ->
          []
      end)
      |> Map.new()

    flat_vars =
      dropped
      |> Enum.reject(fn {_k, v} -> is_map(v) end)
      |> Map.new(fn {k, v} -> {to_string(k), to_string_safe(v)} end)

    Map.merge(nested_vars, flat_vars)
  end

  defp substitute(template, vars) when is_binary(template) do
    Regex.replace(~r/\{\{(\w+)\}\}/, template, fn _, key ->
      Map.get(vars, key, "")
    end)
  end

  defp to_string_safe(v) when is_binary(v), do: v
  defp to_string_safe(v) when is_integer(v), do: Integer.to_string(v)
  defp to_string_safe(v) when is_float(v), do: Float.to_string(v)
  defp to_string_safe(v) when is_boolean(v), do: to_string(v)
  defp to_string_safe(nil), do: ""
  defp to_string_safe(v), do: inspect(v)
end

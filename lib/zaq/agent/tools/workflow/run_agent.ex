defmodule Zaq.Agent.Tools.Workflow.RunAgent do
  @moduledoc """
  Runs a named configured agent with template-variable substitution.

  Looks up the agent by `agent_name` from the database, uses its `job` field
  (system prompt) verbatim, substitutes `{{variable}}` placeholders in `input`
  using all accumulated workflow params, then invokes `Executor.run/2`.

  The system prompt is deliberately **not** templated: keeping it static lets
  providers cache the prompt prefix across runs. All run-specific/custom data
  belongs in `input` (the user message), never in the system prompt.

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

  alias Zaq.Agent
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Event
  alias Zaq.NodeRouter

  @impl Jido.Action
  def run(%{agent_name: agent_name, input: input} = params, context) do
    case Agent.get_agent_by_name(agent_name) do
      {:ok, agent} -> dispatch_agent_run(agent, input, params, context)
      {:error, :agent_not_found} -> {:error, "agent_not_found:#{agent_name}"}
    end
  end

  defp dispatch_agent_run(agent, input, params, context) do
    node_router = Map.get(context, :node_router, NodeRouter)
    vars = build_vars(params)
    # System prompt is kept verbatim (static) so the prompt prefix stays
    # cacheable across runs; only the user message carries run-specific data.
    system_prompt = agent.job || ""
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
    |> build_event(agent.id, system_prompt)
    |> node_router.dispatch()
    |> Map.get(:response)
    |> handle_response()
  end

  defp build_event(incoming, agent_id, system_prompt) do
    incoming
    |> Event.new(:agent,
      opts: [
        action: :run_pipeline,
        pipeline_opts: [system_prompt: system_prompt, skip_permissions: true]
      ]
    )
    |> Map.put(:assigns, %{agent_selection: %{agent_id: agent_id}})
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

defmodule Zaq.Agent.Tools.Workflow.RunAgent do
  @moduledoc """
  Runs a named configured agent with template-variable substitution.

  Looks up the agent by `agent_name` from the database, retrieves its `job`
  field (system prompt), substitutes `{{variable}}` placeholders using all
  accumulated workflow params, then invokes `Executor.run/2`.

  ## Schema

  - `agent_name` — required. Name of the configured agent in the DB.
  - `input`      — required. The user message / task prompt (also supports `{{variable}}`).

  All other params in the accumulated workflow state are available as
  `{{variable_name}}` substitutions in both `job` and `input`.

  ## Example

      RunAgent.run(
        %{agent_name: "LeadOutreach", input: "Draft email for {{name}} at {{company}}",
          name: "John", company: "Acme"},
        %{run_id: "run-123"}
      )
      # => {:ok, %{output: "Hi John..."}}
  """

  use Jido.Action,
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

  use Zaq.Engine.Workflows.Action

  require Logger

  alias Zaq.Agent
  alias Zaq.Agent.Executor
  alias Zaq.Engine.Messages.Incoming

  @impl Jido.Action
  def run(%{agent_name: agent_name, input: input} = params, context) do
    executor = Map.get(context, :executor, Executor)

    case Agent.get_agent_by_name(agent_name) do
      {:ok, agent} ->
        vars = build_vars(params)
        system_prompt = substitute(agent.job || "", vars)
        resolved_input = substitute(input, vars)

        run_id = Map.get(context, :run_id) || Map.get(context, "run_id")

        incoming = %Incoming{
          content: resolved_input,
          channel_id: "workflow:#{run_id || "anon"}",
          author_id: "workflow",
          provider: :workflow
        }

        outgoing =
          executor.run(incoming,
            agent_id: agent.id,
            system_prompt: system_prompt,
            scope: "workflow:run:#{run_id || "anon"}",
            skip_permissions: true
          )

        if outgoing.metadata[:error] do
          {:error, "agent_failed:#{outgoing.metadata[:reason] || "unknown"}"}
        else
          {:ok, %{output: outgoing.body}}
        end

      {:error, :agent_not_found} ->
        {:error, "agent_not_found:#{agent_name}"}
    end
  end

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

defmodule Zaq.Agent.Tools.Skills.LoadSkill do
  @moduledoc """
  ReAct tool: loads the full instructions for one skill, by name.

  The system prompt carries only a name + description index of the agent's skills
  (`Zaq.Agent.Skills.index_system_prompt/2`). This tool returns the full body of one of
  them as a tool result, plus a list of the skill's reference files.

  ## Scoping

  Lookup is restricted to the invoking agent's own attached, active skills
  (`enabled_skill_ids`, resolved from `:configured_agent_id` in the tool context) — never a
  global lookup. A name outside that set returns not-found without listing what is
  available, so the tool cannot be used to enumerate the skill catalog.

  ## Result

    * `body` — the skill's instructions. Size is capped at write time by
      `Zaq.Agent.Skills.Limits`, so nothing is truncated here. Bytes returned are emitted as
      telemetry.
    * `resources` — the skill's reference files as `%{id, name, provider}`. Names are
      resolved from the datasource on each call rather than stored on the skill row, so a
      rename cannot go stale. `provider` is included because `download_document` requires it
      alongside the id. File *contents* are not returned; the model fetches them with
      `download_document` if it needs them. If the lookup fails, the skill still loads with
      `resources: []`.

  Nothing is recorded: the loaded body lives in the conversation's message context, and a
  repeat call simply returns it again. After a restart the prior tool result replays from
  history.
  """

  @schema Zoi.object(%{
            name: Zoi.string(description: "The exact name of the skill to load.")
          })

  # `id` and `provider` together are the address `download_document` takes; `name` is what
  # the model chooses between. Naming both halves of the address explicitly is deliberate —
  # a model given only an id invents a provider rather than failing.
  @resource_schema Zoi.object(%{
                     id:
                       Zoi.string(
                         description:
                           "Pass as `document_id` to `download_document`. Use verbatim."
                       ),
                     name: Zoi.string(description: "The file's name."),
                     provider:
                       Zoi.string(
                         description:
                           "Pass as `provider` to `download_document`. Use verbatim — do not " <>
                             "substitute or guess a provider key."
                       )
                   })

  @output_schema Zoi.object(%{
                   name: Zoi.string(description: "The loaded skill's name."),
                   instructions: Zoi.string(description: "The skill's full instructions."),
                   resources:
                     Zoi.list(@resource_schema,
                       description:
                         "Reference files this skill bundles. To read one, call " <>
                           "`download_document` with that entry's `provider` and its `id`."
                     )
                 })

  use Zaq.Engine.Workflows.Action,
    name: "load_skill",
    description: """
    Load the full instructions for one of your available skills, by name. The system prompt
    lists each skill's name and what it is for; call this to read a skill's actual
    instructions before following it. Pass the exact skill name from the list.
    """,
    schema: @schema,
    output_schema: @output_schema

  alias Jido.Action.Tool
  alias Zaq.Agent
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.Skill.ReferenceFiles
  alias Zaq.Agent.Skills
  alias Zaq.Agent.TokenEstimator
  alias Zaq.NodeRouter

  require Logger

  # Tool calls arrive from the model with string keys, and a Zoi object keyed by atoms
  # rejects those outright ("is required, at name"). Converting first is what makes the
  # schema usable from an LLM at all.
  @impl Jido.Action
  def on_before_validate_params(params) when is_map(params) do
    {:ok, Tool.convert_params_using_schema(params, schema())}
  end

  def on_before_validate_params(params), do: {:ok, params}

  @impl Jido.Action
  def run(%{name: name}, context) do
    with {:ok, agent} <- fetch_agent(context),
         {:ok, skill} <- fetch_granted_skill(agent, name) do
      resources = load_resources(skill, context)
      emit_telemetry(agent, skill, resources, context)

      {:ok, %{name: skill.name, instructions: skill.body, resources: resources}}
    end
  end

  # Only three fields are surfaced, and the split matters. `id` and `provider` together are
  # the *address* `download_document` takes; omitting either leaves the model unable to
  # construct the call, and it will invent a plausible-looking provider rather than fail.
  # `name` is what it chooses between. Everything else — mime type, size — is description
  # the filename already implies, and `resources` is returned on *every* skill load, so it
  # is context spent on every call. The record still carries those fields if a caller needs
  # them.
  #
  # `ReferenceFiles` degrades an unreachable provider to no records, so a skill whose
  # instructions do not need a file still loads when ingestion is down. The warning is how
  # an operator finds out.
  defp load_resources(skill, context) do
    skill
    |> ReferenceFiles.list(
      node_router: Map.get(context, :node_router, NodeRouter),
      on_error: &warn_unresolved/2
    )
    |> Enum.map(fn {provider, record} ->
      %{id: record.id, name: record.name, provider: provider}
    end)
  end

  defp warn_unresolved(provider, response) do
    Logger.warning("[LoadSkill] could not list #{provider} resources: #{inspect(response)}")
  end

  defp fetch_agent(context) do
    case Map.get(context, :configured_agent_id) do
      nil ->
        # No invoking agent means nothing to scope resolution to. Refuse rather than fall
        # back to a global lookup — a nil scope must never widen access.
        {:error, "load_skill is not available in this context."}

      id ->
        case Agent.get_agent(id) do
          %ConfiguredAgent{} = agent -> {:ok, agent}
          _ -> {:error, "load_skill is not available in this context."}
        end
    end
  end

  # The grant check: the skill must be attached to THIS agent and active. `enabled_for_agent/1`
  # already filters to active, granted skills, so a hallucinated, unattached, or inactive
  # name all collapse to the same clean not-found — and the error names only the requested
  # skill, never the catalog.
  defp fetch_granted_skill(agent, name) do
    case Enum.find(Skills.enabled_for_agent(agent), &(&1.name == name)) do
      nil -> {:error, "Skill #{inspect(name)} is not available to this agent."}
      skill -> {:ok, skill}
    end
  end

  defp emit_telemetry(agent, skill, resources, context) do
    body = skill.body || ""
    telemetry = Map.get(context, :telemetry_module, :telemetry)

    telemetry.execute(
      [:zaq, :agent, :skill, :load],
      %{
        body_bytes: byte_size(body),
        body_tokens: TokenEstimator.estimate(body),
        resource_count: length(resources)
      },
      %{skill_id: skill.id, skill_name: skill.name, configured_agent_id: agent.id}
    )
  rescue
    # Telemetry must never take down a tool call.
    e ->
      Logger.warning("[LoadSkill] telemetry emit failed: #{Exception.message(e)}")
      :ok
  end
end

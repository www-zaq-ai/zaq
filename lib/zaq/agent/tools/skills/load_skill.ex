defmodule Zaq.Agent.Tools.Skills.LoadSkill do
  @moduledoc """
  ReAct tool: loads the full instructions for one skill, by name.

  This is the second half of progressive disclosure. The system prompt carries only a
  name + description **index** of the agent's skills (`Zaq.Agent.Skills.index_system_prompt/2`);
  when the model decides it needs one, it calls this tool and the full body arrives **as a
  tool result** in the conversation.

  ## Scoping — the security boundary

  Resolution is scoped to the **invoking agent's own attached, active skills**
  (`enabled_skill_ids`), read from `:configured_agent_id` in the tool context. It is never a
  global lookup. An agent cannot load a skill it was not granted, and the not-found path
  **never lists the available skills** — unlike upstream `Jido.AI.Actions.Skill.LoadSkill`,
  which leaks the whole catalog on a miss (agentjido/jido_ai#323, gap G3).

  ## Stateless by design

  Nothing is recorded. The loaded body lives in the conversation's message context for the
  life of the agent server — the transcript *is* the record of what was loaded, so a
  separate activation set could only ever disagree with it (which is exactly upstream gap
  G2). A repeat call simply returns the body again; that is idempotent, not a bug. After a
  cold restart the prior tool result replays from history, so the instructions are already
  back in context.

  The body size is capped at **write time** (`Zaq.Agent.Skills.Limits`), so nothing needs
  bounding here; this tool emits telemetry on the bytes it returns so the cap can be tuned
  on evidence.

  ## Resources

  Progressive disclosure now spans two levels. The body arrives here; the skill's reference
  *files* do not. They are listed as `%{id, name, provider}` — enough for the model to pick
  one and call `download_document` — and their bytes are fetched only if it does.

  `provider` travels with each entry because it is half the address, not description:
  `download_document` requires it, and a model given only an id will guess a provider that
  does not exist rather than fail.

  The skill row stores only `{file_id, provider}`, so names come from the datasource at
  load time rather than from a denormalized copy that a rename would invalidate. If that
  lookup fails the skill still loads with `resources: []`: a skill whose instructions need
  no file must not become unusable because the ingestion role is down.
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
  alias Zaq.Agent.Skill.Resources
  alias Zaq.Agent.Skills
  alias Zaq.Agent.TokenEstimator
  alias Zaq.Contracts.RecordPage
  alias Zaq.Event
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

  # The skill row stores `{file_id, provider}` and nothing else — the datasource owns names,
  # so a copy on the skill would go stale the moment a file is renamed. That means one
  # dispatch per provider to turn ids into something the model can choose between.
  #
  # Three fields are surfaced, and the split matters. `id` and `provider` together are the
  # *address* `download_document` takes; omitting either leaves the model unable to
  # construct the call, and it will invent a plausible-looking provider rather than fail.
  # `name` is what it chooses between. Everything else — mime type, size — is description
  # the filename already implies, and `resources` is returned on *every* skill load, so it
  # is context spent on every call. The record still carries those fields if a caller needs
  # them.
  defp load_resources(skill, context) do
    skill
    |> Resources.references()
    |> Enum.group_by(&Map.get(&1, "provider"), &Map.get(&1, "file_id"))
    |> Enum.flat_map(fn {provider, file_ids} -> describe(provider, file_ids, context) end)
  end

  # A skill whose instructions do not need a file must keep working when the ingestion role
  # is unreachable, so a failure here degrades to "no resources" rather than failing the
  # load. The warning is how an operator finds out.
  defp describe(provider, file_ids, context) do
    node_router = Map.get(context, :node_router, NodeRouter)

    response =
      %{provider: provider, params: %{"file_ids" => file_ids}}
      |> Event.new(:channels, opts: [action: :data_source_list_files])
      |> node_router.dispatch()
      |> Map.get(:response)

    case response do
      {:ok, %RecordPage{records: records}} ->
        Enum.map(records, &%{id: &1.id, name: &1.name, provider: provider})

      other ->
        Logger.warning("[LoadSkill] could not list #{provider} resources: #{inspect(other)}")

        []
    end
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

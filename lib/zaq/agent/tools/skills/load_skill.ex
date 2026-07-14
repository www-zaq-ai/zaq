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
  """

  use Zaq.Engine.Workflows.Action,
    name: "load_skill",
    description: """
    Load the full instructions for one of your available skills, by name. The system prompt
    lists each skill's name and what it is for; call this to read a skill's actual
    instructions before following it. Pass the exact skill name from the list.
    """,
    schema: [
      name: [type: :string, required: true, doc: "The exact name of the skill to load."]
    ],
    output_schema: [
      name: [type: :string, required: true, doc: "The loaded skill's name."],
      instructions: [type: :string, required: true, doc: "The skill's full instructions."],
      resources: [
        type: {:list, :any},
        required: false,
        doc: "Resource files the skill bundles, loadable on demand (always [] in Part 1; Part 2)."
      ]
    ]

  alias Zaq.Agent
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.Skills
  alias Zaq.Agent.TokenEstimator

  require Logger

  @impl Jido.Action
  def run(%{name: name}, context) do
    with {:ok, agent} <- fetch_agent(context),
         {:ok, skill} <- fetch_granted_skill(agent, name) do
      emit_telemetry(agent, skill)

      {:ok,
       %{
         name: skill.name,
         instructions: skill.body,
         # Resource loading is Part 2 (§ M8). The key is present now so the tool's output
         # shape stays stable when resources land — adding them is non-breaking.
         resources: []
       }}
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

  defp emit_telemetry(agent, skill) do
    body = skill.body || ""

    :telemetry.execute(
      [:zaq, :agent, :skill, :load],
      %{body_bytes: byte_size(body), body_tokens: TokenEstimator.estimate(body)},
      %{skill_id: skill.id, skill_name: skill.name, configured_agent_id: agent.id}
    )
  rescue
    # Telemetry must never take down a tool call.
    e ->
      Logger.warning("[LoadSkill] telemetry emit failed: #{Exception.message(e)}")
      :ok
  end
end

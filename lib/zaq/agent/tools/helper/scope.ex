defmodule Zaq.Agent.Tools.Helper.Scope do
  @moduledoc """
  Resolves the invoking agent, and the skills granted to it, for tools that need either.

  `fetch_agent/2` answers *which agent is asking* — a question any tool reading
  `:configured_agent_id` has, which is why this sits under `Tools.Helper` rather than beside
  one tool family. `fetch_granted_skill/2` answers *is this skill actually granted to it*, and
  is used by `Zaq.Agent.Tools.Skills.LoadSkill` and `LoadSkillReference`. Together they are
  the security boundary for the whole skills surface, so they live in one place — two copies
  of a permission check is one copy that gets fixed and one that does not.

  They sit in the tool layer, not in `Zaq.Agent.Skills`, because the refusals they return are
  **prose written for a model**. Message wording is a tool concern; a domain module handing
  back sentences for an LLM to read would be the wrong seam.

  ## Two rules worth keeping intact

    * **A `nil` agent id refuses.** It never falls back to a global lookup — deriving
      permissions from the absence of a scope is how an unscoped call quietly becomes an
      admin one.
    * **Not-found never lists anything.** A skill that does not exist, one that is inactive,
      and one that exists but is not granted to this agent all produce the same message, and
      that message names only what was asked for — never the catalog, never the skill's files
      (upstream gap G3). Anything else turns a refusal into an enumeration primitive.
  """

  alias Zaq.Agent
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.Skill
  alias Zaq.Agent.Skills

  @doc """
  The agent invoking the tool, read from `:configured_agent_id`.

  `tool_name` only shapes the refusal message. Returns the same message whether the scope is
  missing or the id resolves to nothing, so a caller cannot probe for valid agent ids.
  """
  @spec fetch_agent(map(), String.t()) :: {:ok, ConfiguredAgent.t()} | {:error, String.t()}
  def fetch_agent(context, tool_name) do
    with id when not is_nil(id) <- Map.get(context, :configured_agent_id),
         %ConfiguredAgent{} = agent <- Agent.get_agent(id) do
      {:ok, agent}
    else
      _ -> {:error, "#{tool_name} is not available in this context."}
    end
  end

  @doc """
  The named skill, if it is granted to `agent` and active.

  `Zaq.Agent.Skills.enabled_for_agent/1` already filters to active, granted skills, so a
  hallucinated name, an unattached one and an inactive one all collapse to the same
  not-found — which is the point.
  """
  @spec fetch_granted_skill(ConfiguredAgent.t(), String.t()) ::
          {:ok, Skill.t()} | {:error, String.t()}
  def fetch_granted_skill(agent, name) do
    case Enum.find(Skills.enabled_for_agent(agent), &(&1.name == name)) do
      nil -> {:error, "Skill #{inspect(name)} is not available to this agent."}
      skill -> {:ok, skill}
    end
  end
end

defmodule Zaq.Agent.Skills do
  @moduledoc """
  Context for BO-managed agent skills.

  CRUD and search for `Zaq.Agent.Skill` records, plus the single home for
  composing an agent's *effective* runtime configuration from its attached
  skills: `effective_tool_keys/2` (agent tools ∪ skill tools),
  `effective_mcp_endpoint_ids/2` (agent MCP endpoints ∪ skill MCP endpoints),
  and `effective_system_prompt/2` (job + rendered skill instructions).

  Runtime propagation of skill changes to live agent servers is handled by
  `Zaq.Agent.RuntimeSync`, not here.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.MCP
  alias Zaq.Agent.Skill
  alias Zaq.Agent.Tools.Registry
  alias Zaq.Repo
  alias Zaq.Utils.ParseUtils

  @skill_prompt_header "You have access to the following skills:"

  @spec list_skills() :: [Skill.t()]
  def list_skills do
    Skill
    |> order_by(asc: :name)
    |> Repo.all()
  end

  @spec list_active_skills() :: [Skill.t()]
  def list_active_skills do
    Skill
    |> where(active: true)
    |> order_by(asc: :name)
    |> Repo.all()
  end

  @doc """
  Fetches skills by id, preserving only existing records.

  Ghost ids (deleted skills still referenced by an agent) are silently
  dropped — callers get only real skills back.
  """
  @spec get_skills_by_ids([integer()]) :: [Skill.t()]
  def get_skills_by_ids([]), do: []

  def get_skills_by_ids(ids) when is_list(ids) do
    Skill
    |> where([s], s.id in ^ids)
    |> order_by(asc: :name)
    |> Repo.all()
  end

  @doc """
  Returns the active skills attached to a configured agent.

  Ghost ids (deleted skills) and inactive skills are dropped, so the result is
  always safe to feed into runtime composition. Never hits the database when
  the agent has no skill ids.
  """
  @spec enabled_for_agent(ConfiguredAgent.t()) :: [Skill.t()]
  def enabled_for_agent(%ConfiguredAgent{enabled_skill_ids: ids}) when ids in [nil, []], do: []

  def enabled_for_agent(%ConfiguredAgent{enabled_skill_ids: ids}) do
    ids
    |> get_skills_by_ids()
    |> Enum.filter(& &1.active)
  end

  @doc """
  Unions the agent's own `enabled_tool_keys` with the tool keys of the given
  skills.

  Skill tool keys that no longer exist in `Zaq.Agent.Tools.Registry` are
  dropped so a tool removed from the registry cannot break every agent using
  the skill. The agent's own keys are passed through unfiltered — resolution
  errors for those surface exactly as they do today.
  """
  @spec effective_tool_keys(ConfiguredAgent.t(), [Skill.t()]) :: [String.t()]
  def effective_tool_keys(%ConfiguredAgent{} = agent, skills) when is_list(skills) do
    skill_keys =
      skills
      |> Enum.flat_map(&(&1.tool_keys || []))
      |> Enum.filter(&Registry.valid_tool_key?/1)

    Enum.uniq((agent.enabled_tool_keys || []) ++ skill_keys)
  end

  @doc """
  Unions the agent's own `enabled_mcp_endpoint_ids` with the MCP endpoint ids of
  the given skills.

  Ids are deduped; ordering keeps the agent's own ids first. Endpoints that are
  disabled or deleted are tolerated here (they are skipped at runtime sync), so
  a removed endpoint cannot break every agent using the skill.
  """
  @spec effective_mcp_endpoint_ids(ConfiguredAgent.t(), [Skill.t()]) :: [integer()]
  def effective_mcp_endpoint_ids(%ConfiguredAgent{} = agent, skills) when is_list(skills) do
    skill_ids = Enum.flat_map(skills, &(&1.enabled_mcp_endpoint_ids || []))

    Enum.uniq((agent.enabled_mcp_endpoint_ids || []) ++ skill_ids)
  end

  @doc """
  Composes the agent's effective system prompt: its `job` followed by the
  rendered instruction blocks of the given skills.

  Returns the bare job when there are no skills, and just the skills block when
  the job is empty.
  """
  @spec effective_system_prompt(ConfiguredAgent.t(), [Skill.t()]) :: String.t()
  def effective_system_prompt(%ConfiguredAgent{} = agent, skills) when is_list(skills) do
    job = agent.job || ""

    case render_prompt_block(skills) do
      nil -> job
      block when job == "" -> block
      block -> job <> "\n\n" <> block
    end
  end

  @doc """
  Renders skills as a markdown block for system prompt injection.

  Mirrors the `Jido.AI.Skill.Prompt` format: a header line followed by a
  `## name` section per skill with its description and body. Returns `nil`
  for an empty list.
  """
  @spec render_prompt_block([Skill.t()]) :: String.t() | nil
  def render_prompt_block([]), do: nil

  def render_prompt_block(skills) when is_list(skills) do
    sections =
      Enum.map(skills, fn %Skill{} = skill ->
        header = "## #{skill.name}"

        [header, skill.description, skill.body]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join("\n\n")
      end)

    Enum.join([@skill_prompt_header | sections], "\n\n")
  end

  @spec get_skill!(integer() | String.t()) :: Skill.t()
  def get_skill!(id), do: Repo.get!(Skill, parse_id!(id))

  @spec get_skill(integer() | String.t()) :: Skill.t() | nil
  def get_skill(id) do
    case ParseUtils.parse_int_strict(id) do
      {:ok, int_id} -> Repo.get(Skill, int_id)
      :error -> nil
    end
  end

  @spec create_skill(map()) :: {:ok, Skill.t()} | {:error, Ecto.Changeset.t()}
  def create_skill(attrs) do
    %Skill{}
    |> Skill.changeset(attrs)
    |> validate_mcp_endpoint_ids()
    |> Repo.insert()
  end

  @spec update_skill(Skill.t(), map()) :: {:ok, Skill.t()} | {:error, Ecto.Changeset.t()}
  def update_skill(%Skill{} = skill, attrs) do
    skill
    |> Skill.changeset(attrs)
    |> validate_mcp_endpoint_ids()
    |> Repo.update()
  end

  @spec delete_skill(Skill.t()) :: {:ok, Skill.t()} | {:error, Ecto.Changeset.t()}
  def delete_skill(%Skill{} = skill), do: Repo.delete(skill)

  @spec change_skill(Skill.t(), map()) :: Ecto.Changeset.t()
  def change_skill(%Skill{} = skill, attrs \\ %{}) do
    skill
    |> Skill.changeset(attrs)
    |> validate_mcp_endpoint_ids()
  end

  # Rejects endpoint ids that do not map to an existing MCP.Endpoint, mirroring
  # `Zaq.Agent.validate_mcp_endpoint_assignments/1`. The schema changeset only
  # sanitizes ids (positive integers, deduped); existence is a runtime concern
  # so the DB lookup lives in the context, not the schema.
  defp validate_mcp_endpoint_ids(%Changeset{} = changeset) do
    ids = Changeset.get_field(changeset, :enabled_mcp_endpoint_ids) || []

    unknown_ids =
      ids
      |> Enum.uniq()
      |> Enum.reject(&match?(%MCP.Endpoint{}, MCP.get_mcp_endpoint(&1)))

    if unknown_ids == [] do
      changeset
    else
      Changeset.add_error(
        changeset,
        :enabled_mcp_endpoint_ids,
        "contains unknown MCP endpoint ids: #{Enum.join(unknown_ids, ", ")}"
      )
    end
  end

  @doc """
  Searches skills by tags and/or free text.

  ## Filters

  - `:tags` — list of tags; matches skills tagged with ANY of them
    (case-insensitive, tags are stored normalized)
  - `:q` — case-insensitive substring match on name and description
  - `:active` — restrict to active (`true`) or inactive (`false`) skills
  """
  @spec search_skills(map()) :: [Skill.t()]
  def search_skills(filters) when is_map(filters) do
    Skill
    |> filter_by_tags(filters[:tags])
    |> filter_by_query(filters[:q])
    |> filter_by_active(filters[:active])
    |> order_by(asc: :name)
    |> Repo.all()
  end

  defp filter_by_tags(query, tags) when is_list(tags) do
    normalized =
      tags
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
      |> Enum.reject(&(&1 == ""))

    if normalized == [] do
      query
    else
      where(query, [s], fragment("? && ?", s.tags, ^normalized))
    end
  end

  defp filter_by_tags(query, _), do: query

  defp filter_by_query(query, q) when is_binary(q) and q != "" do
    pattern = "%#{escape_like(q)}%"

    where(
      query,
      [s],
      ilike(s.name, ^pattern) or ilike(coalesce(s.description, ""), ^pattern)
    )
  end

  defp filter_by_query(query, _), do: query

  defp filter_by_active(query, active) when is_boolean(active),
    do: where(query, active: ^active)

  defp filter_by_active(query, _), do: query

  # Escapes PostgreSQL LIKE/ILIKE special characters so user input is treated literally.
  defp escape_like(str), do: String.replace(str, ["\\", "%", "_"], &"\\#{&1}")

  defp parse_id!(id) do
    case ParseUtils.parse_int_strict(id) do
      {:ok, int} -> int
      :error -> raise ArgumentError, "invalid id: #{inspect(id)}"
    end
  end
end

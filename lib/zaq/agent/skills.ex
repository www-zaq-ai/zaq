defmodule Zaq.Agent.Skills do
  @moduledoc """
  Context for BO-managed agent skills.

  CRUD and search for `Zaq.Agent.Skill` records, plus the two things composed from
  an agent's attached skills:

    * **Provisioning** — `provisioned_tool_keys/2` (agent tools ∪ skill tools) and
      `provisioned_mcp_endpoint_ids/2` (agent endpoints ∪ skill endpoints). These are
      **ZAQ** concepts: what must be installed on the live agent server when a skill is
      attached. The union is correct, and `Zaq.Agent.RuntimeSync` consumes it.
    * **The prompt** — `system_prompt/3`, which is progressive by default:
      `to_spec/1` converts each record to a `%Jido.AI.Skill.Spec{}` and the prompt carries
      a **name + description index only**. Bodies are pulled on demand by the `load_skill`
      tool. `effective_system_prompt/2` is the old eager renderer, kept as the
      `:skills_progressive_disclosure` flag's off-path until rollout is confirmed.

  Runtime propagation of skill changes to live agent servers is handled by
  `Zaq.Agent.RuntimeSync`, not here.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Jido.AI.Skill.Prompt
  alias Jido.AI.Skill.Spec
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.MCP
  alias Zaq.Agent.Skill
  alias Zaq.Agent.Skills.Validation
  alias Zaq.Agent.Tools.Registry
  alias Zaq.Repo
  alias Zaq.Utils.ParseUtils

  require Logger

  @skill_prompt_header "You have access to the following skills:"

  # The index tells the model the skills exist and how to read one. Without the second
  # sentence the model sees a catalog it has no way to open.
  @skill_index_header """
  You have access to the following skills. Each entry lists a skill's name and what it is \
  for — not its instructions. To follow a skill, first call the `load_skill` tool with its \
  name to read the full instructions.\
  """

  @spec list_skills() :: [Skill.t()]
  def list_skills do
    Skill
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
  # Provisioned onto an agent whenever it has ≥1 active skill, and dropped (via RuntimeSync's
  # managed-tool diff) when its last skill is detached — an index-only prompt is useless
  # without it, and a skill-less agent has no reason to carry it.
  @load_skill_key "skills.load_skill"

  @spec provisioned_tool_keys(ConfiguredAgent.t(), [Skill.t()]) :: [String.t()]
  def provisioned_tool_keys(%ConfiguredAgent{} = agent, skills) when is_list(skills) do
    skill_keys =
      skills
      |> Enum.flat_map(&provided_tool_keys/1)
      |> Enum.filter(&Registry.valid_tool_key?/1)

    base = (agent.enabled_tool_keys || []) ++ skill_keys
    keys = if skills == [], do: base, else: base ++ [@load_skill_key]

    Enum.uniq(keys)
  end

  # Reads the new column, falling back to the old one for any row written by a node still
  # running pre-dual-write code. Drop the fallback with the `tool_keys` column.
  defp provided_tool_keys(%Skill{} = skill) do
    case skill.provided_tool_keys do
      keys when is_list(keys) and keys != [] -> keys
      _ -> skill.tool_keys || []
    end
  end

  @doc """
  Unions the agent's own `enabled_mcp_endpoint_ids` with the MCP endpoint ids of
  the given skills.

  Ids are deduped; ordering keeps the agent's own ids first. Endpoints that are
  disabled or deleted are tolerated here (they are skipped at runtime sync), so
  a removed endpoint cannot break every agent using the skill.
  """
  @spec provisioned_mcp_endpoint_ids(ConfiguredAgent.t(), [Skill.t()]) :: [integer()]
  def provisioned_mcp_endpoint_ids(%ConfiguredAgent{} = agent, skills) when is_list(skills) do
    skill_ids = Enum.flat_map(skills, &(&1.enabled_mcp_endpoint_ids || []))

    Enum.uniq((agent.enabled_mcp_endpoint_ids || []) ++ skill_ids)
  end

  @doc """
  Converts a skill record into a standard `%Jido.AI.Skill.Spec{}`.

  Goes through `Validation` — i.e. through a real SKILL.md round trip — so the Spec is
  exactly what the file format would produce. A record that cannot produce a valid Spec
  returns `{:error, _}`; callers **skip** it rather than crashing agent boot.

  `tags` are attached after parsing on purpose: they are a Jido extension, not an Open
  Agent Skills frontmatter field, so emitting them into SKILL.md would make the document
  non-conformant.
  """
  @spec to_spec(Skill.t()) :: {:ok, Spec.t()} | {:error, term()}
  def to_spec(%Skill{} = skill) do
    attrs = %{
      name: skill.name,
      description: skill.description,
      body: skill.body,
      allowed_tools: skill.allowed_tools || []
    }

    case Validation.validate(attrs) do
      {:ok, %Spec{} = spec, _diagnostics} -> {:ok, %{spec | tags: skill.tags || []}}
      {:error, errors} -> {:error, errors}
    end
  end

  @doc """
  Converts skill records to Specs, dropping any that cannot produce a valid one.

  An invalid record must never take an agent down with it — but it must not vanish
  quietly either, so each drop is logged. A skill that disappears from the index with no
  trace is the hardest possible failure to diagnose from the outside.
  """
  @spec to_specs([Skill.t()]) :: [Spec.t()]
  def to_specs(skills) when is_list(skills) do
    Enum.flat_map(skills, fn %Skill{} = skill ->
      case to_spec(skill) do
        {:ok, spec} ->
          [spec]

        {:error, errors} ->
          Logger.warning(
            "[Skills] skill #{inspect(skill.name)} (id=#{skill.id}) is not a valid " <>
              "Open Agent Skills spec and was omitted from the agent's index: #{inspect(errors)}"
          )

          []
      end
    end)
  end

  @doc """
  The agent's system prompt: its `job`, followed by its skills.

  Progressive by default — the skills section is a **name + description index**, and the
  model pulls a body on demand via `load_skill`. With `:skills_progressive_disclosure`
  disabled, falls back to the eager renderer that concatenates every body.
  """
  @spec system_prompt(ConfiguredAgent.t(), [Skill.t()], keyword()) :: String.t()
  def system_prompt(%ConfiguredAgent{} = agent, skills, opts \\ []) when is_list(skills) do
    if progressive_disclosure?(opts) do
      index_system_prompt(agent, skills)
    else
      effective_system_prompt(agent, skills)
    end
  end

  @doc """
  Composes `job` + a name/description **index** of the agent's skills — never bodies.

  Uses `Jido.AI.Skill.Prompt.render/2` with `include_body: false`, so the token cost is
  O(skill count) rather than O(total body bytes). `allowed_tools` is rendered for free by
  the same call: visible to the model, but not enforced in Part 1.
  """
  @spec index_system_prompt(ConfiguredAgent.t(), [Skill.t()]) :: String.t()
  def index_system_prompt(%ConfiguredAgent{} = agent, skills) when is_list(skills) do
    job = agent.job || ""

    index =
      skills
      |> to_specs()
      |> Prompt.render(include_body: false, header: @skill_index_header)

    case index do
      "" -> job
      index when job == "" -> index
      index -> job <> "\n\n" <> index
    end
  end

  # Defaults ON: the `load_skill` tool exists (Step 5) and is auto-provisioned to any agent
  # with skills, so an index-only prompt is always actionable. Set
  # `config :zaq, :skills_progressive_disclosure, false` to fall back to the eager renderer
  # (the rollback path for an answer-quality regression, until Step 7 removes it).
  defp progressive_disclosure?(opts) do
    Zaq.Config.get(:zaq, :skills_progressive_disclosure, true, opts)
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

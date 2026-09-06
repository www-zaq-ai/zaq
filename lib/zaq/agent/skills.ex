defmodule Zaq.Agent.Skills do
  @moduledoc """
  Context for BO-managed agent skills.

  CRUD and search for `Zaq.Agent.Skill` records, plus the two things composed from
  an agent's attached skills:

    * **Provisioning** — `provisioned_tool_keys/2` (agent tools ∪ skill tools) and
      `provisioned_mcp_endpoint_ids/2` (agent endpoints ∪ skill endpoints). These are
      **ZAQ** concepts: what must be installed on the live agent server when a skill is
      attached. The union is correct, and `Zaq.Agent.RuntimeSync` consumes it.
    * **Native skill specs** — `to_spec/1` converts each record to a
      `%Jido.AI.Skill.Spec{}`. `Zaq.Agent.Factory` prepares Jido's index and native
      tools; bodies are pulled on demand by `load_skill`.

  Runtime propagation of skill changes to live agent servers is handled by
  `Zaq.Agent.RuntimeSync`, not here.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Jido.AI.Skill.Spec
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.MCP
  alias Zaq.Agent.Skill
  alias Zaq.Agent.Skill.Resource
  alias Zaq.Agent.Skills.Validation
  alias Zaq.Agent.Tools.Registry
  alias Zaq.Repo
  alias Zaq.System
  alias Zaq.Utils.ParseUtils

  require Logger

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
  @spec provisioned_tool_keys(ConfiguredAgent.t(), [Skill.t()]) :: [String.t()]
  def provisioned_tool_keys(%ConfiguredAgent{} = agent, skills) when is_list(skills) do
    skill_keys =
      skills
      |> Enum.flat_map(&provided_tool_keys/1)
      |> Enum.filter(&Registry.valid_tool_key?/1)

    Enum.uniq((agent.enabled_tool_keys || []) ++ skill_keys)
  end

  defp provided_tool_keys(%Skill{} = skill), do: skill.provided_tool_keys || []

  @doc "Returns the persisted runtime resources for a skill."
  @spec list_skill_resources(Skill.t()) :: [Resource.t()]
  def list_skill_resources(%Skill{id: skill_id}) do
    Resource
    |> where(skill_id: ^skill_id)
    |> order_by(asc: :name)
    |> Repo.all()
  end

  @doc "Fetches a skill resource by Jido's opaque provider resource id."
  @spec get_skill_resource_by_provider_id(Skill.t(), String.t()) :: Resource.t() | nil
  def get_skill_resource_by_provider_id(%Skill{id: skill_id}, provider_resource_id)
      when is_binary(provider_resource_id) do
    Repo.get_by(Resource, skill_id: skill_id, provider_resource_id: provider_resource_id)
  end

  @doc "Creates or updates the persisted resource row for an uploaded skill resource."
  @spec upsert_skill_resource(Skill.t(), map()) :: {:ok, Resource.t()} | {:error, Changeset.t()}
  def upsert_skill_resource(%Skill{id: skill_id}, attrs) when is_map(attrs) do
    attrs = Map.put(attrs, :skill_id, skill_id)

    %Resource{}
    |> Resource.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace, [:name, :resource_type, :size, :mime_type, :modified_at, :updated_at]},
      conflict_target: [:skill_id, :provider_resource_id],
      returning: true
    )
  end

  @doc "Deletes one persisted skill resource row."
  @spec delete_skill_resource(Resource.t()) :: {:ok, Resource.t()} | {:error, Changeset.t()}
  def delete_skill_resource(%Resource{} = resource), do: Repo.delete(resource)

  @doc "Returns the pinned or global default resource location for a skill."
  def resource_location(%Skill{} = skill) do
    pinned = %{
      provider: skill.resource_provider,
      config_id: skill.resource_config_id,
      scope_id: skill.resource_scope_id,
      folder_id: skill.resource_folder_id,
      folder_path: skill.resource_folder_path
    }

    if pinned.provider && pinned.config_id do
      {:ok, Map.put(pinned, :pinned?, true)}
    else
      case System.get_skill_resource_config() do
        %{provider: provider, config_id: config_id} = config
        when is_binary(provider) and is_integer(config_id) ->
          {:ok, Map.put(config, :pinned?, false)}

        _ ->
          {:error, :skill_resource_location_not_configured}
      end
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
      license: skill.license,
      compatibility: skill.compatibility,
      metadata: skill.metadata || %{},
      allowed_tools: skill.allowed_tools || []
    }

    case Validation.validate(attrs) do
      {:ok, %Spec{} = spec} -> {:ok, %{spec | source: nil, tags: skill.tags || []}}
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

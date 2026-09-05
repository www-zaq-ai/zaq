defmodule Zaq.Agent.Skill do
  @moduledoc """
  Schema for BO-managed agent skills.

  A skill bundles an Agent Skills manifest, markdown instruction `body`, a set of
  tool keys from `Zaq.Agent.Tools.Registry`, a set of MCP endpoint ids
  (`enabled_mcp_endpoint_ids`), and searchable `tags`. Skills are attached to
  configured agents and take effect at runtime through the same hot-patch path as
  `enabled_tool_keys` / `enabled_mcp_endpoint_ids`.

  Field-shape validation against the Open Agent Skills spec (name format, length caps,
  `allowed-tools` encoding) is **owned by `Jido.AI.Skill.Loader`**, reached through
  `Zaq.Agent.Skills.Validation` — ZAQ does not reimplement it. This module keeps only the
  validations Jido cannot do: that `provided_tool_keys` exist in `Tools.Registry`, and
  that `resource_root` is a safe relative path.

  ## Two kinds of "tools" — do not conflate them

    * `provided_tool_keys` — **ZAQ**. `Zaq.Agent.Tools.Registry` keys that ZAQ
      *provisions* onto the live agent server when this skill is attached. Unioned
      across an agent's skills by `Zaq.Agent.Skills`, installed by
      `Zaq.Agent.RuntimeSync`.
    * `allowed_tools` — **Open Agent Skills standard**. Tool *names* this skill is
      permitted to use. It maps straight to `Jido.AI.Skill.Spec.allowed_tools` and is
      stored and rendered into the prompt, but **not enforced** (enforcement needs
      per-skill request scoping, which Jido does not yet express).

  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Zaq.Agent.Skills.Limits
  alias Zaq.Agent.Skills.Validation
  alias Zaq.Agent.TokenEstimator
  alias Zaq.Agent.Tools.Registry

  @type t :: %__MODULE__{}

  schema "agent_skills" do
    field :name, :string
    field :description, :string
    field :body, :string
    field :license, :string
    field :compatibility, :string
    field :metadata, :map, default: %{}
    field :provided_tool_keys, {:array, :string}, default: []
    field :allowed_tools, {:array, :string}, default: []
    field :enabled_mcp_endpoint_ids, {:array, :integer}, default: []
    field :resource_provider, :string
    field :resource_config_id, :integer
    field :resource_scope_id, :string
    field :resource_folder_id, :string
    field :resource_folder_path, :string
    field :resource_root, :string
    field :tags, {:array, :string}, default: []
    field :active, :boolean, default: true

    has_many :resources, Zaq.Agent.Skill.Resource

    timestamps(type: :utc_datetime)
  end

  # `description` is required by the Open Agent Skills spec and by
  # `Jido.AI.Skill.Loader.parse/3` in strict mode. It is not optional metadata: it is the
  # only thing the model sees about a skill in the prompt index, and it is what the model
  # decides to call `load_skill` on. A skill without one cannot be converted to a
  # `%Jido.AI.Skill.Spec{}` at all.
  @required_fields ~w(name description body)a
  @optional_fields ~w(license compatibility metadata provided_tool_keys allowed_tools
                      enabled_mcp_endpoint_ids resource_provider resource_config_id
                      resource_scope_id resource_folder_id resource_folder_path
                      resource_root tags active)a

  def changeset(skill, attrs) do
    skill
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_tool_keys()
    |> normalize_allowed_tools()
    |> normalize_metadata()
    |> normalize_resource_location()
    |> normalize_mcp_endpoint_ids()
    |> normalize_tags()
    |> validate_resource_root()
    |> validate_against_spec()
    |> validate_body_size()
    |> unique_constraint(:name)
  end

  # Jido caps `name`, `description` and `compatibility`, but NOT `body`. An unbounded body
  # defeats progressive disclosure — it stays in the agent's context for the server's life
  # once loaded — so ZAQ caps it. See `Zaq.Agent.Skills.Limits` for why this is a global
  # write-time rail.
  defp validate_body_size(changeset) do
    body = get_field(changeset, :body) || ""
    bytes = byte_size(body)
    tokens = TokenEstimator.estimate(body)

    max_bytes = Limits.get(:skill_body_max_bytes)
    max_tokens = Limits.get(:skill_body_max_tokens)
    warning_tokens = Limits.get(:skill_body_warning_tokens)

    cond do
      bytes > max_bytes ->
        add_error(changeset, :body, "is too large (max #{max_bytes} bytes)", count: bytes)

      tokens > max_tokens ->
        add_error(changeset, :body, "is too long (max #{max_tokens} tokens)", count: tokens)

      tokens > warning_tokens ->
        changeset

      true ->
        changeset
    end
  end

  # `resource_root` is a path RELATIVE to a storage volume. This is a syntactic guard
  # only — it rejects the shapes that could escape a volume, and nothing more.
  #
  # It deliberately does NOT resolve the path against the filesystem. Resolution belongs
  # to the `:storage` role, which is the only node guaranteed to have the volume
  # mounted (a changeset must not make a cross-service call, and the BO node may not see
  # the volume at all). `Skill.Resources` re-checks containment at read time, on the
  # storage node, which is the authoritative check.
  defp validate_resource_root(changeset) do
    case get_field(changeset, :resource_root) do
      nil ->
        changeset

      "" ->
        put_change(changeset, :resource_root, nil)

      root when is_binary(root) ->
        cond do
          String.starts_with?(root, "/") ->
            add_error(changeset, :resource_root, "must be relative to a storage volume")

          ".." in Path.split(root) ->
            add_error(changeset, :resource_root, "must not contain \"..\"")

          true ->
            changeset
        end
    end
  end

  defp normalize_resource_location(changeset) do
    changeset
    |> normalize_blank_string(:resource_provider)
    |> normalize_blank_string(:resource_scope_id)
    |> normalize_blank_string(:resource_folder_id)
    |> normalize_blank_string(:resource_folder_path)
  end

  defp normalize_blank_string(changeset, field) do
    case get_field(changeset, field) do
      value when is_binary(value) -> put_change(changeset, field, blank_to_nil(value))
      _ -> changeset
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # Field-shape validation (name format, length caps, allowed-tools encoding) is owned by
  # `Jido.AI.Skill.Loader` via `Validation.validate/1` — ZAQ does not reimplement it. See
  # `Zaq.Agent.Skills.Validation` for why this round-trips through SKILL.md text, and for
  # the guard that rejects lossy SKILL.md serialization.
  #
  # Runs last, and only on an otherwise-valid changeset: it needs normalized values, and
  # there is no point reporting a malformed name on a record that is already failing.
  defp validate_against_spec(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp validate_against_spec(changeset) do
    attrs = %{
      name: get_field(changeset, :name),
      description: get_field(changeset, :description),
      body: get_field(changeset, :body),
      license: get_field(changeset, :license),
      compatibility: get_field(changeset, :compatibility),
      metadata: get_field(changeset, :metadata) || %{},
      allowed_tools: get_field(changeset, :allowed_tools) || []
    }

    case Validation.validate(attrs) do
      {:ok, _spec} ->
        changeset

      {:error, errors} ->
        Enum.reduce(errors, changeset, fn {field, message}, acc ->
          add_error(acc, field, message)
        end)
    end
  end

  # OAS tool *names*, not `Tools.Registry` keys — so there is nothing to validate them
  # against. Normalize only.
  defp normalize_allowed_tools(changeset) do
    tools =
      changeset
      |> get_field(:allowed_tools)
      |> List.wrap()
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    put_change(changeset, :allowed_tools, tools)
  end

  defp normalize_metadata(changeset) do
    metadata = get_field(changeset, :metadata) || %{}

    if is_map(metadata) do
      put_change(
        changeset,
        :metadata,
        Map.new(metadata, fn {key, value} -> {to_string(key), value} end)
      )
    else
      changeset
    end
  end

  defp normalize_mcp_endpoint_ids(changeset) do
    ids =
      changeset
      |> get_field(:enabled_mcp_endpoint_ids)
      |> List.wrap()
      |> Enum.filter(&(is_integer(&1) and &1 > 0))
      |> Enum.uniq()

    put_change(changeset, :enabled_mcp_endpoint_ids, ids)
  end

  defp normalize_tags(changeset) do
    tags =
      changeset
      |> get_field(:tags)
      |> List.wrap()
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    put_change(changeset, :tags, tags)
  end

  # Keys already persisted are grandfathered: a tool key can be retired from the
  # Registry without making every skill that references it uneditable.
  defp validate_tool_keys(%Ecto.Changeset{data: data} = changeset) do
    keys = get_field(changeset, :provided_tool_keys) || []

    original_keys = Map.get(data, :provided_tool_keys) || []

    newly_unknown =
      keys
      |> Enum.uniq()
      |> Enum.reject(&(Registry.valid_tool_key?(&1) or &1 in original_keys))

    if newly_unknown == [] do
      changeset
    else
      add_error(
        changeset,
        :provided_tool_keys,
        "contains unknown tools: #{Enum.join(newly_unknown, ", ")}"
      )
    end
  end
end

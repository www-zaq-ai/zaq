defmodule Zaq.Agent.Skill do
  @moduledoc """
  Schema for BO-managed agent skills.

  A skill bundles a markdown instruction `body` with a set of tool keys from
  `Zaq.Agent.Tools.Registry`, a set of MCP endpoint ids (`enabled_mcp_endpoint_ids`),
  and searchable `tags`. Skills are attached to configured agents and take effect at
  runtime through the same hot-patch path as `enabled_tool_keys` /
  `enabled_mcp_endpoint_ids` (tool + MCP sync + per-ask system prompt injection).

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

  `tool_keys` is the pre-split column. It is dual-written with `provided_tool_keys`
  for the rollout window and dropped once every node runs the new code — see
  `changeset/2`.
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
    field :tool_keys, {:array, :string}, default: []
    field :provided_tool_keys, {:array, :string}, default: []
    field :allowed_tools, {:array, :string}, default: []
    field :enabled_mcp_endpoint_ids, {:array, :integer}, default: []
    field :resource_root, :string
    field :diagnostics, :map
    field :tags, {:array, :string}, default: []
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  # `description` is required by the Open Agent Skills spec and by
  # `Jido.AI.Skill.Loader.parse/3` in strict mode. It is not optional metadata: it is the
  # only thing the model sees about a skill in the prompt index, and it is what the model
  # decides to call `load_skill` on. A skill without one cannot be converted to a
  # `%Jido.AI.Skill.Spec{}` at all.
  @required_fields ~w(name description body)a
  @optional_fields ~w(tool_keys provided_tool_keys allowed_tools
                      enabled_mcp_endpoint_ids resource_root tags active)a

  def changeset(skill, attrs) do
    skill
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_tool_keys()
    |> dual_write_tool_keys()
    |> normalize_allowed_tools()
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
  # write-time rail. Runs after validate_against_spec so it can fold a warning into the
  # diagnostics that step produced.
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
        put_body_warning(changeset, tokens, warning_tokens)

      true ->
        changeset
    end
  end

  # A non-blocking notice, merged into the diagnostics cache so the BO can badge it exactly
  # like a Jido warning — same channel, no separate surfacing path.
  defp put_body_warning(changeset, tokens, warning_tokens) do
    warning = %{
      "type" => "body_large",
      "severity" => "warning",
      "message" =>
        "Skill body is large (~#{tokens} tokens, warns above #{warning_tokens}). " <>
          "Consider moving bulk into references/ resources loaded on demand."
    }

    diagnostics = get_field(changeset, :diagnostics) || %{"warnings" => [], "warning_count" => 0}
    warnings = Map.get(diagnostics, "warnings", []) ++ [warning]

    updated =
      diagnostics
      |> Map.put("warnings", warnings)
      |> Map.put("warning_count", length(warnings))

    put_change(changeset, :diagnostics, updated)
  end

  # `resource_root` is a path RELATIVE to an ingestion volume. This is a syntactic guard
  # only — it rejects the shapes that could escape a volume, and nothing more.
  #
  # It deliberately does NOT resolve the path against the filesystem. Resolution belongs
  # to the `:ingestion` role, which is the only node guaranteed to have the volume
  # mounted (a changeset must not make a cross-service call, and the BO node may not see
  # the volume at all). `Skill.Resources` re-checks containment at read time, on the
  # ingestion node, which is the authoritative check.
  defp validate_resource_root(changeset) do
    case get_field(changeset, :resource_root) do
      nil ->
        changeset

      "" ->
        put_change(changeset, :resource_root, nil)

      root when is_binary(root) ->
        cond do
          String.starts_with?(root, "/") ->
            add_error(changeset, :resource_root, "must be relative to an ingestion volume")

          ".." in Path.split(root) ->
            add_error(changeset, :resource_root, "must not contain \"..\"")

          true ->
            changeset
        end
    end
  end

  # Field-shape validation (name format, length caps, allowed-tools encoding) is owned by
  # `Jido.AI.Skill.Loader` via `Validation.validate/1` — ZAQ does not reimplement it. See
  # `Zaq.Agent.Skills.Validation` for why this round-trips through SKILL.md text, and for
  # the truncation guard that stops Jido silently shortening an over-long field.
  #
  # Runs last, and only on an otherwise-valid changeset: it needs normalized values, and
  # there is no point reporting a malformed name on a record that is already failing.
  defp validate_against_spec(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp validate_against_spec(changeset) do
    attrs = %{
      name: get_field(changeset, :name),
      description: get_field(changeset, :description),
      body: get_field(changeset, :body),
      allowed_tools: get_field(changeset, :allowed_tools) || []
    }

    case Validation.validate(attrs) do
      {:ok, _spec, diagnostics} ->
        # Cached so the BO can badge a skill as having warnings without re-parsing every
        # row on a list view. Refreshed on every write.
        put_change(changeset, :diagnostics, diagnostics)

      {:error, errors} ->
        Enum.reduce(errors, changeset, fn {field, message}, acc ->
          add_error(acc, field, message)
        end)
    end
  end

  # `tool_keys` and `provided_tool_keys` must hold the same value for the whole rollout
  # window: a node still running the old code reads `tool_keys`, while new code writes
  # `provided_tool_keys`. Mirror whichever side the caller wrote onto the other.
  # `provided_tool_keys` wins if both were supplied — it is the field that survives.
  # Delete this together with the `tool_keys` column, once every node runs the new code.
  defp dual_write_tool_keys(changeset) do
    case {fetch_change(changeset, :provided_tool_keys), fetch_change(changeset, :tool_keys)} do
      {{:ok, keys}, _} -> put_change(changeset, :tool_keys, keys)
      {:error, {:ok, keys}} -> put_change(changeset, :provided_tool_keys, keys)
      {:error, :error} -> changeset
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

  # Runs *before* `dual_write_tool_keys/1`, so the caller's own field is still the only
  # one changed — the error is reported where they wrote, whichever column that was.
  # Keys already persisted are grandfathered: a tool key can be retired from the
  # Registry without making every skill that references it uneditable.
  defp validate_tool_keys(%Ecto.Changeset{data: data} = changeset) do
    field =
      case fetch_change(changeset, :provided_tool_keys) do
        {:ok, _} ->
          :provided_tool_keys

        :error ->
          if match?({:ok, _}, fetch_change(changeset, :tool_keys)),
            do: :tool_keys,
            else: :provided_tool_keys
      end

    keys = get_field(changeset, field) || []

    original_keys =
      (Map.get(data, :provided_tool_keys) || []) ++ (Map.get(data, :tool_keys) || [])

    newly_unknown =
      keys
      |> Enum.uniq()
      |> Enum.reject(&(Registry.valid_tool_key?(&1) or &1 in original_keys))

    if newly_unknown == [] do
      changeset
    else
      add_error(
        changeset,
        field,
        "contains unknown tools: #{Enum.join(newly_unknown, ", ")}"
      )
    end
  end
end

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
  that `resources` has the expected shape.

  ## `resources`

  A namespace map — `%{"references" => [%{"file_id" => …, "provider" => …}]}` — naming the
  files a skill bundles. Files are addressed by **document id**, not by path, so the skill
  row never has to know where a file lives and renaming one in ingestion cannot orphan it.
  Metadata (name, mime type) is deliberately absent: the datasource owns it, and a copy
  here would go stale. `Zaq.Agent.Tools.Skills.LoadSkill` resolves names at load time.

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
    field :resources, :map, default: %{"references" => []}
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
  # Reserved namespaces inside `resources`. Only "references" carries data today.
  @resource_kinds ~w(references)

  @required_fields ~w(name description body)a
  @optional_fields ~w(tool_keys provided_tool_keys allowed_tools
                      enabled_mcp_endpoint_ids resources tags active)a

  def changeset(skill, attrs) do
    skill
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_tool_keys()
    |> dual_write_tool_keys()
    |> normalize_allowed_tools()
    |> normalize_mcp_endpoint_ids()
    |> normalize_tags()
    |> validate_resources()
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

  # `resources` is a namespace map. Only `"references"` is populated today; `"skills"` and
  # `"assets"` are reserved so they can be added without another migration. Unknown keys are
  # rejected rather than ignored, so a typo surfaces at write time instead of silently
  # producing a skill whose files are invisible.
  #
  # A reference is `%{"file_id" => binary, "provider" => binary}` and nothing else. There is
  # deliberately no denormalized name or mime type here: the datasource owns that metadata,
  # and a copy in this row would go stale the moment a file is renamed in ingestion.
  defp validate_resources(changeset) do
    case get_field(changeset, :resources) do
      nil -> put_change(changeset, :resources, %{"references" => []})
      resources when is_map(resources) -> validate_resource_map(changeset, resources)
      _ -> add_error(changeset, :resources, "must be a map")
    end
  end

  defp validate_resource_map(changeset, resources) do
    case Map.keys(resources) -- @resource_kinds do
      [] -> validate_references(changeset, Map.get(resources, "references", []))
      unknown -> add_error(changeset, :resources, "has unknown keys: #{Enum.join(unknown, ", ")}")
    end
  end

  defp validate_references(changeset, references) when is_list(references) do
    if Enum.all?(references, &valid_reference?/1) do
      put_change(changeset, :resources, %{"references" => dedupe_references(references)})
    else
      add_error(
        changeset,
        :resources,
        ~s(references must each be %{"file_id" => string, "provider" => string})
      )
    end
  end

  defp validate_references(changeset, _references),
    do: add_error(changeset, :resources, "references must be a list")

  defp valid_reference?(%{"file_id" => file_id, "provider" => provider} = reference)
       when is_binary(file_id) and is_binary(provider) do
    file_id != "" and provider != "" and Map.keys(reference) -- ["file_id", "provider"] == []
  end

  defp valid_reference?(_reference), do: false

  # The same file referenced twice would be listed twice to the model and downloaded twice.
  defp dedupe_references(references), do: Enum.uniq_by(references, &Map.get(&1, "file_id"))

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

defmodule Zaq.Agent.Skill do
  @moduledoc """
  Schema for BO-managed agent skills.

  A skill bundles a markdown instruction `body` with a set of tool keys from
  `Zaq.Agent.Tools.Registry` and searchable `tags`. Skills are attached to
  configured agents and take effect at runtime through the same hot-patch path
  as `enabled_tool_keys` (tool sync + per-ask system prompt injection).

  Name constraints mirror the agentskills.io format enforced by
  `Jido.AI.Skill.Loader` (lowercase kebab-case, max 64 chars) so records stay
  convertible to `Jido.AI.Skill.Spec` structs.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Zaq.Agent.Tools.Registry

  @name_regex ~r/^[a-z0-9]+(-[a-z0-9]+)*$/
  @max_name_length 64
  @max_description_length 1024

  @type t :: %__MODULE__{}

  schema "agent_skills" do
    field :name, :string
    field :description, :string
    field :body, :string
    field :tool_keys, {:array, :string}, default: []
    field :tags, {:array, :string}, default: []
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name body)a
  @optional_fields ~w(description tool_keys tags active)a

  def changeset(skill, attrs) do
    skill
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 2, max: @max_name_length)
    |> validate_format(:name, @name_regex,
      message: "must be lowercase kebab-case (letters, digits, hyphens)"
    )
    |> validate_length(:description, max: @max_description_length)
    |> validate_tool_keys()
    |> normalize_tags()
    |> unique_constraint(:name)
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

  defp validate_tool_keys(%Ecto.Changeset{data: data} = changeset) do
    keys = get_field(changeset, :tool_keys) || []
    original_keys = Map.get(data, :tool_keys) || []

    newly_unknown =
      keys
      |> Enum.uniq()
      |> Enum.reject(&(Registry.valid_tool_key?(&1) or &1 in original_keys))

    if newly_unknown == [] do
      changeset
    else
      add_error(
        changeset,
        :tool_keys,
        "contains unknown tools: #{Enum.join(newly_unknown, ", ")}"
      )
    end
  end
end

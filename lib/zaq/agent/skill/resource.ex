defmodule Zaq.Agent.Skill.Resource do
  @moduledoc """
  Persisted resource entry for a BO-managed Agent Skill.

  The row is the runtime resource manifest. Jido receives `provider_resource_id`
  as an opaque provider ID and ZAQ resolves that ID back to the data-source
  document only when the resource is loaded.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Zaq.Agent.Skill
  alias Zaq.Agent.Skill.Resources

  @type t :: %__MODULE__{}

  schema "agent_skill_resources" do
    field :provider_resource_id, :string
    field :name, :string
    field :resource_type, :string, default: "reference"
    field :size, :integer, default: 0
    field :mime_type, :string
    field :modified_at, :utc_datetime

    belongs_to :skill, Skill

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(skill_id provider_resource_id name resource_type size)a
  @optional_fields ~w(mime_type modified_at)a

  def changeset(resource, attrs) do
    resource
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> normalize_resource_type()
    |> validate_number(:size, greater_than_or_equal_to: 0)
    |> validate_length(:provider_resource_id, min: 1, max: 1024)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:resource_type, Resources.resource_types())
    |> foreign_key_constraint(:skill_id)
    |> unique_constraint([:skill_id, :provider_resource_id])
    |> unique_constraint([:skill_id, :name])
  end

  defp normalize_resource_type(changeset) do
    type =
      changeset
      |> get_field(:resource_type)
      |> Resources.normalize_resource_type()

    put_change(changeset, :resource_type, type)
  end
end

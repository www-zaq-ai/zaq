defmodule Zaq.Agent.ConfiguredAgent do
  @moduledoc "Schema for BO-managed custom agents."

  use Ecto.Schema

  import Ecto.Changeset

  alias Zaq.Agent.Tools.Registry
  alias Zaq.System.AIProviderCredential

  @strategies ~w(react cot)
  @type t :: %__MODULE__{}

  schema "configured_agents" do
    field :name, :string
    field :description, :string
    field :job, :string
    field :model, :string
    field :enabled_tool_keys, {:array, :string}, default: []
    field :enabled_mcp_endpoint_ids, {:array, :integer}, default: []
    field :conversation_enabled, :boolean, default: false
    field :strategy, :string, default: "react"
    field :advanced_options, :map, default: %{}
    field :active, :boolean, default: true
    field :idle_time_seconds, :integer
    field :memory_context_max_size, :integer

    belongs_to :credential, AIProviderCredential

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name job model credential_id strategy)a
  @optional_fields ~w(description enabled_tool_keys enabled_mcp_endpoint_ids conversation_enabled advanced_options active idle_time_seconds memory_context_max_size)a

  def changeset(configured_agent, attrs) do
    configured_agent
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 2, max: 255)
    |> validate_inclusion(:strategy, @strategies)
    |> validate_tool_keys()
    |> normalize_mcp_endpoint_ids()
    |> validate_number(:idle_time_seconds, greater_than: 0)
    |> validate_number(:memory_context_max_size, greater_than: 0)
    |> unique_constraint(:name)
    |> foreign_key_constraint(:credential_id)
  end

  defp normalize_mcp_endpoint_ids(changeset) do
    ids = get_field(changeset, :enabled_mcp_endpoint_ids) || []
    put_change(changeset, :enabled_mcp_endpoint_ids, Enum.uniq(ids))
  end

  defp validate_tool_keys(changeset) do
    keys = get_field(changeset, :enabled_tool_keys) || []

    unknown =
      keys
      |> Enum.uniq()
      |> Enum.reject(&Registry.valid_tool_key?/1)

    if unknown == [] do
      changeset
    else
      add_error(
        changeset,
        :enabled_tool_keys,
        "contains unknown tools: #{Enum.join(unknown, ", ")}"
      )
    end
  end
end

defmodule Zaq.Agent.MCP.Endpoint do
  @moduledoc "Schema for BO-managed MCP endpoint configurations."

  use Ecto.Schema

  import Ecto.Changeset

  alias Zaq.Repo

  @types ~w(local remote)
  @statuses ~w(enabled disabled)
  @type t :: %__MODULE__{}

  schema "mcp_endpoints" do
    field :name, :string
    field :type, :string
    field :status, :string, default: "disabled"
    field :timeout_ms, :integer, default: 5000

    field :command, :string
    field :args, {:array, :string}, default: []

    field :url, :string
    field :headers, :map, default: %{}
    field :secret_headers, :map, default: %{}
    field :environments, :map, default: %{}
    field :secret_environments, :map, default: %{}

    field :settings, :map, default: %{}
    field :predefined_id, :string

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name type status timeout_ms)a
  @optional_fields ~w(command args url headers secret_headers environments secret_environments settings predefined_id)a

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(endpoint, attrs) do
    endpoint
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:name, min: 2, max: 255)
    |> validate_number(:timeout_ms, greater_than: 0)
    |> validate_conditional_fields()
    |> validate_map_field(:headers)
    |> validate_map_field(:secret_headers)
    |> validate_map_field(:environments)
    |> validate_map_field(:secret_environments)
    |> validate_map_field(:settings)
    |> validate_key_value_map_strings(:headers)
    |> validate_key_value_map_strings(:secret_headers)
    |> validate_key_value_map_strings(:environments)
    |> validate_key_value_map_strings(:secret_environments)
    |> unsafe_validate_unique(:name, Repo)
    |> unique_constraint(:name)
    |> unique_constraint(:predefined_id)
  end

  defp validate_conditional_fields(changeset) do
    case get_field(changeset, :type) do
      "local" -> validate_required(changeset, [:command])
      "remote" -> validate_required(changeset, [:url])
      _ -> changeset
    end
  end

  defp validate_map_field(changeset, field) do
    case get_field(changeset, field) do
      map when is_map(map) -> changeset
      _ -> add_error(changeset, field, "must be a map")
    end
  end

  defp validate_key_value_map_strings(changeset, field) do
    map = get_field(changeset, field)

    if is_map(map) and not string_key_value_map?(map) do
      add_error(changeset, field, "must contain only string keys and values")
    else
      changeset
    end
  end

  defp string_key_value_map?(map) do
    Enum.all?(map, fn {k, v} -> is_binary(k) and is_binary(v) end)
  end
end

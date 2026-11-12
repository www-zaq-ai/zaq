defmodule Zaq.Permissions.ResourcePolicy do
  @moduledoc """
  One confidentiality policy per resource, separate from person/team ACL grants.

  Classification and clearance overrides are independent. Nil inherits, while
  explicit zero overrides inheritance. These fields describe the target resource,
  not this policy record's own sensitivity. Coordinates are immutable after insert.
  Authorization and target existence are checked by the owning policy boundary.
  Document/folder targets are source-owned permission identities; ingestion rows
  are not independent policy targets. Coordinate validation is not source proof.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Zaq.ResourcePolicies.ResourceRef

  @level_fields [:classification_level, :clearance_level]

  schema "resource_policies" do
    field :resource_type, :string
    field :resource_id, :string
    field :classification_level, :integer
    field :clearance_level, :integer
    field :lock_version, :integer, default: 1

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc "Validates explicit overrides and fences edits with an optimistic version lock."
  @spec changeset(t(), term()) :: Ecto.Changeset.t()
  def changeset(policy, attrs) when is_map(attrs) and not is_struct(attrs) do
    params = normalize_params(attrs)

    policy
    |> cast(params, [:resource_type, :resource_id | @level_fields], empty_values: [])
    |> validate_number(:classification_level,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 2_147_483_647
    )
    |> validate_number(:clearance_level,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 2_147_483_647
    )
    |> validate_required([:resource_type, :resource_id])
    |> validate_coordinates()
    |> immutable_coordinates(policy)
    |> unique_constraint(:resource_id, name: :resource_policies_target_index)
    |> check_constraint(:classification_level,
      name: :resource_policies_classification_nonnegative
    )
    |> check_constraint(:clearance_level, name: :resource_policies_clearance_nonnegative)
    |> lock_for_edit(policy)
  end

  def changeset(policy, _),
    do: policy |> change() |> add_error(:base, "must be a map of settings")

  defp normalize_params(attrs) do
    Enum.reduce([:resource_type, :resource_id | @level_fields], %{}, fn field, params ->
      string_key = Atom.to_string(field)

      cond do
        Map.has_key?(attrs, field) ->
          Map.put(params, string_key, Map.fetch!(attrs, field))

        Map.has_key?(attrs, string_key) ->
          Map.put(params, string_key, Map.fetch!(attrs, string_key))

        true ->
          params
      end
    end)
  end

  defp validate_coordinates(changeset) do
    case ResourceRef.new(
           {get_field(changeset, :resource_type), get_field(changeset, :resource_id)}
         ) do
      {:ok, _} -> changeset
      {:error, _} -> add_error(changeset, :resource_id, "must identify a registered resource")
    end
  end

  defp immutable_coordinates(changeset, %{__meta__: %{state: :loaded}}) do
    Enum.reduce([:resource_type, :resource_id], changeset, fn field, acc ->
      if changed?(acc, field), do: add_error(acc, field, "cannot be changed"), else: acc
    end)
  end

  defp immutable_coordinates(changeset, _), do: changeset

  defp lock_for_edit(changeset, %{__meta__: %{state: :loaded}}),
    do: optimistic_lock(changeset, :lock_version)

  defp lock_for_edit(changeset, _), do: changeset
end

defmodule Zaq.Accounts.PeoplePermissionGrant do
  @moduledoc """
  Explicit People capability grant for all people or one team. Owns the closed,
  ordered permission vocabulary; separate from resource rights and BO roles.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @permissions [
    %{permission: :access_profile, label: "Access profile"},
    %{permission: :access_message_history, label: "Access message history"},
    %{permission: :share_conversations, label: "Share conversations"}
  ]
  @strings Enum.map(@permissions, &Atom.to_string(&1.permission))
  @type t :: %__MODULE__{}

  schema "people_permission_grants" do
    field :scope_type, :string
    belongs_to :scope, Zaq.Accounts.Team
    field :permission, :string
    timestamps(type: :utc_datetime)
  end

  @doc "Ordered capability metadata for the matrix and permission consumers."
  @spec permissions() :: [map()]
  def permissions, do: @permissions

  @doc "Casts only known atoms or exact storage strings; never creates atoms."
  @spec cast_permission(term()) :: {:ok, atom()} | {:error, :invalid_permission}
  for %{permission: permission} <- @permissions do
    def cast_permission(unquote(permission)), do: {:ok, unquote(permission)}
    def cast_permission(unquote(Atom.to_string(permission))), do: {:ok, unquote(permission)}
  end

  def cast_permission(_), do: {:error, :invalid_permission}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [:scope_type, :scope_id, :permission])
    |> validate_required([:scope_type, :permission])
    |> validate_inclusion(:scope_type, ["all_people", "team"])
    |> validate_inclusion(:permission, @strings)
    |> validate_scope_id()
    |> check_constraint(:scope_type, name: :people_permission_grants_scope_type_check)
    |> check_constraint(:scope_id, name: :people_permission_grants_scope_id_check)
    |> check_constraint(:permission, name: :people_permission_grants_permission_check)
    |> foreign_key_constraint(:scope_id, name: :people_permission_grants_scope_id_fkey)
    |> unique_constraint(:permission, name: :people_permission_grants_all_people_unique)
    |> unique_constraint([:scope_id, :permission], name: :people_permission_grants_team_unique)
  end

  defp validate_scope_id(changeset) do
    case {get_field(changeset, :scope_type), get_field(changeset, :scope_id)} do
      {"team", _} -> validate_required(changeset, [:scope_id])
      {"all_people", id} when not is_nil(id) -> add_error(changeset, :scope_id, "must be empty")
      _ -> changeset
    end
  end
end

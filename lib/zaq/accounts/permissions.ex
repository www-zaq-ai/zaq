defmodule Zaq.Accounts.Permissions do
  @moduledoc """
  Role-based access control helpers for ZAQ.

  Determines which role IDs a user can retrieve chunks for,
  based on their own role and any cross-role access configured in
  `role.meta["accessible_role_ids"]`.
  """

  @doc """
  Returns the list of role IDs whose chunks are accessible to the given user.

  Always includes the user's own `role_id`. If `role.meta["accessible_role_ids"]`
  is set, those IDs are included as well (additive cross-role access).

  Requires `user.role` to be preloaded.

  Returns `[]` if the user has no role assigned.
  """
  def list_accessible_role_ids(user) do
    case user.role_id do
      nil -> []
      own_id -> [own_id]
    end
  end

  @doc """
  Returns true if the user has a role assigned (can perform retrievals).
  """
  def can_retrieve?(user), do: user.role_id != nil

  @doc """
  Returns true if the user has a role assigned (can trigger ingestion).
  """
  def can_ingest?(user), do: user.role_id != nil
end

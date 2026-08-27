defmodule Zaq.Permissions.PermissionRevoker do
  @moduledoc """
  Behaviour for deleting resource permission rows.

  The default implementation delegates to `Zaq.Repo.delete/1`.
  """

  @callback delete(Ecto.Schema.t()) :: {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}

  @doc false
  @spec delete(Ecto.Schema.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def delete(permission), do: Zaq.Repo.delete(permission)
end

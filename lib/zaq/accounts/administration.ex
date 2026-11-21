defmodule Zaq.Accounts.Administration do
  @moduledoc """
  Guarded BO mutations of roles and user role assignments.

  Reuses Accounts persistence, retaining its validation and profile behavior.
  Role CRUD and assignment require the current super-admin role. An unchanged
  role on a profile edit is not a new assignment. Callers supply authenticated
  actor context separately from mutation parameters; bootstrap/internal Accounts
  operations do not become a BO permission bypass through this boundary.
  """

  alias Zaq.Accounts
  alias Zaq.Accounts.{BOActor, BOAuthorization, Role, User}
  alias Zaq.MapUtils
  alias Zaq.Repo

  @operations [:create_role, :update_role, :delete_role, :create_user, :update_user]

  @doc "Runs a declared BO mutation, rechecking current authority for every call."
  @spec run(term(), atom(), term()) :: {:ok, struct()} | {:error, term()}
  def run(actor, operation, params)

  def run(actor, :update_user, params) when is_map(params) and not is_struct(params) do
    with {:ok, _user} <- BOActor.current_user(actor),
         {:ok, id} <- id(MapUtils.fetch(params, :id)),
         {:ok, attrs} <- attributes(params),
         %User{} = user <- Accounts.get_user(id),
         :ok <- authorize_assignment(actor, user, attrs) do
      Accounts.update_user(user, attrs)
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def run(actor, operation, params)
      when operation in @operations and is_map(params) and not is_struct(params) do
    with {:ok, _user} <- BOAuthorization.authorize(actor, :manage_roles) do
      mutate(operation, params)
    end
  end

  def run(_, operation, _) when operation not in @operations, do: {:error, :invalid_operation}
  def run(_, _, _), do: {:error, :invalid_request}

  defp mutate(:create_role, params), do: Accounts.create_role(params)
  defp mutate(:create_user, params), do: Accounts.create_user_with_password(params)

  defp mutate(:update_role, params) do
    with {:ok, role} <- find_role(params),
         {:ok, attrs} <- attributes(params) do
      Accounts.update_role(role, attrs)
    end
  end

  defp mutate(:delete_role, params) do
    with {:ok, role} <- find_role(params), do: Accounts.delete_role(role)
  end

  defp find_role(params) do
    with {:ok, id} <- id(MapUtils.fetch(params, :id)) do
      case Repo.get(Role, id) do
        nil -> {:error, :not_found}
        role -> {:ok, role}
      end
    end
  end

  defp authorize_assignment(actor, user, attrs) do
    case Ecto.Type.cast(:id, MapUtils.fetch(attrs, :role_id)) do
      {:ok, role_id} when is_integer(role_id) and role_id != user.role_id ->
        case BOAuthorization.authorize(actor, :manage_roles) do
          {:ok, _user} -> :ok
          {:error, _} = error -> error
        end

      _ ->
        :ok
    end
  end

  defp id(value) do
    case Ecto.Type.cast(:id, value) do
      {:ok, id} when is_integer(id) and id > 0 -> {:ok, id}
      _ -> {:error, :invalid_request}
    end
  end

  defp attributes(params) do
    case MapUtils.fetch(params, :attrs) do
      attrs when is_map(attrs) and not is_struct(attrs) -> {:ok, attrs}
      _ -> {:error, :invalid_request}
    end
  end
end

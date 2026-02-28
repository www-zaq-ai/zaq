defmodule Zaq.Accounts do
  import Ecto.Query
  alias Zaq.Repo
  alias Zaq.Accounts.{User, Role}

  # Roles

  def create_role(attrs) do
    attrs = parse_meta(attrs)

    %Role{}
    |> Role.changeset(attrs)
    |> Repo.insert()
  end

  def get_role!(id), do: Repo.get!(Role, id)

  def get_role_by_name(name), do: Repo.get_by(Role, name: name)

  def list_roles, do: Repo.all(Role)

  def update_role(role, attrs) do
    attrs = parse_meta(attrs)

    role
    |> Role.changeset(attrs)
    |> Repo.update()
  end

  def delete_role(role) do
    Repo.delete(role)
  end

  defp parse_meta(%{"meta" => meta} = attrs) when is_binary(meta) do
    case Jason.decode(meta) do
      {:ok, decoded} -> Map.put(attrs, "meta", decoded)
      {:error, _} -> Map.put(attrs, "meta", %{})
    end
  end

  defp parse_meta(attrs), do: attrs

  # Users

  def create_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  def get_user!(id), do: Repo.get!(User, id) |> Repo.preload(:role)

  def get_user_by_username(username) do
    User
    |> Repo.get_by(username: username)
    |> Repo.preload(:role)
  end

  def list_users do
    User
    |> preload(:role)
    |> Repo.all()
  end

  def update_user(user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  def delete_user(user) do
    Repo.delete(user)
  end

  def create_user_with_password(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> User.password_changeset(attrs)
    |> Repo.insert()
  end

  def change_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> Repo.update()
  end

  def authenticate_user(username, password) do
    case get_user_by_username(username) do
      %User{password_hash: nil, must_change_password: true} = user ->
        # First login — check against env credentials
        config = Application.get_env(:zaq, :super_admin)

        if config[:username] == username and config[:password] == password do
          {:ok, user}
        else
          {:error, :invalid_password}
        end

      %User{password_hash: hash} = user when not is_nil(hash) ->
        if Bcrypt.verify_pass(password, hash) do
          {:ok, user}
        else
          {:error, :invalid_password}
        end

      nil ->
        Bcrypt.no_user_verify()
        {:error, :not_found}
    end
  end
end

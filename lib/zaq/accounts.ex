defmodule Zaq.Accounts do
  @moduledoc """
  Context for users, roles, and authentication.

  Handles CRUD for `User` and `Role`, password authentication and change flows,
  super-admin seeding on startup, and role-based permission lookups.
  """
  import Ecto.Query
  alias Zaq.Accounts.{Role, User}
  alias Zaq.Repo

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

  def list_roles_with_user_counts do
    Role
    |> join(:left, [r], u in assoc(r, :users))
    |> group_by([r], [r.id, r.name, r.meta, r.inserted_at, r.updated_at])
    |> select([r, u], %{
      id: r.id,
      name: r.name,
      meta: r.meta,
      users_count: count(u.id),
      inserted_at: r.inserted_at,
      updated_at: r.updated_at
    })
    |> Repo.all()
  end

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

  def count_users do
    Repo.aggregate(User, :count, :id)
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

  def change_user_password(actor, user, attrs) do
    attrs = normalize_password_attrs(attrs)

    with :ok <- authorize_password_change(actor, user),
         {:ok, attrs} <- validate_password_change_attrs(attrs),
         :ok <- verify_current_password(user, attrs.current_password) do
      case change_password(user, %{password: attrs.new_password}) do
        {:ok, updated_user} -> {:ok, updated_user}
        {:error, changeset} -> {:error, remap_password_changeset(changeset)}
      end
    end
  end

  def get_user_by_email(email) when is_binary(email) do
    User
    |> Repo.get_by(email: email)
    |> Repo.preload(:role)
  end

  def get_user_by_email(_), do: nil

  @reset_token_salt "password_reset"
  @reset_token_max_age 3_600

  def generate_password_reset_token(%User{} = user) do
    payload = %{user_id: user.id, secret: password_secret(user)}
    Phoenix.Token.sign(ZaqWeb.Endpoint, @reset_token_salt, payload)
  end

  def verify_password_reset_token(token) do
    case Phoenix.Token.verify(ZaqWeb.Endpoint, @reset_token_salt, token,
           max_age: @reset_token_max_age
         ) do
      {:ok, %{user_id: user_id, secret: secret}} ->
        user = get_user!(user_id)

        if password_secret(user) == secret do
          {:ok, user}
        else
          {:error, :invalid_token}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp password_secret(%User{password_hash: hash}) when is_binary(hash),
    do: String.slice(hash, -8, 8)

  defp password_secret(_), do: ""

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

  defp normalize_password_attrs(attrs) when is_map(attrs) do
    %{
      current_password: Map.get(attrs, :current_password) || Map.get(attrs, "current_password"),
      new_password: Map.get(attrs, :new_password) || Map.get(attrs, "new_password"),
      new_password_confirmation:
        Map.get(attrs, :new_password_confirmation) ||
          Map.get(attrs, "new_password_confirmation")
    }
  end

  defp authorize_password_change(%User{id: actor_id}, %User{id: target_id})
       when actor_id == target_id,
       do: :ok

  defp authorize_password_change(_actor, _target) do
    {:error, password_error_changeset(:new_password, "you can only change your own password")}
  end

  defp validate_password_change_attrs(attrs) do
    types = %{
      current_password: :string,
      new_password: :string,
      new_password_confirmation: :string
    }

    changeset =
      {%{}, types}
      |> Ecto.Changeset.cast(attrs, Map.keys(types))
      |> Ecto.Changeset.validate_required([
        :current_password,
        :new_password,
        :new_password_confirmation
      ])
      |> Ecto.Changeset.validate_confirmation(:new_password,
        required: true,
        message: "does not match confirmation"
      )

    Ecto.Changeset.apply_action(changeset, :validate)
  end

  defp verify_current_password(%User{password_hash: hash}, current_password)
       when is_binary(hash) and is_binary(current_password) do
    if Bcrypt.verify_pass(current_password, hash) do
      :ok
    else
      {:error, password_error_changeset(:current_password, "is invalid")}
    end
  end

  defp verify_current_password(_user, _current_password) do
    {:error, password_error_changeset(:current_password, "is invalid")}
  end

  defp password_error_changeset(field, message) do
    empty_password_changeset()
    |> Ecto.Changeset.add_error(field, message)
  end

  defp remap_password_changeset(changeset) do
    changeset_with_errors =
      Enum.reduce(changeset.errors, empty_password_changeset(), fn
        {:password, {message, opts}}, acc ->
          Ecto.Changeset.add_error(acc, :new_password, message, opts)

        {field, {message, opts}}, acc ->
          Ecto.Changeset.add_error(acc, field, message, opts)
      end)

    %{changeset_with_errors | action: :validate}
  end

  defp empty_password_changeset do
    {%{}, %{current_password: :string, new_password: :string, new_password_confirmation: :string}}
    |> Ecto.Changeset.change()
  end
end

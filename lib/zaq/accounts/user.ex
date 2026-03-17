defmodule Zaq.Accounts.User do
  @moduledoc """
  Ecto schema for users. Each user has a unique username, a hashed password, and belongs to a role.
  The schema includes a virtual password field for handling password input and a flag to indicate if the user must change their password on next login.
  Changesets are provided for creating/updating users and for handling password changes, including hashing the password using Bcrypt.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Accounts.PasswordPolicy

  @type t :: %__MODULE__{}

  schema "users" do
    field :username, :string
    field :email, :string
    field :password, :string, virtual: true
    field :password_hash, :string
    field :must_change_password, :boolean, default: true

    belongs_to :role, Zaq.Accounts.Role

    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :email, :role_id, :must_change_password, :password])
    |> validate_required([:username, :email, :role_id])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email address"
    )
    |> unique_constraint(:username)
    |> unique_constraint(:email)
  end

  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> PasswordPolicy.validate(:password)
    |> hash_password()
  end

  defp hash_password(%{valid?: true, changes: %{password: password}} = changeset) do
    changeset
    |> put_change(:password_hash, Bcrypt.hash_pwd_salt(password))
    |> put_change(:must_change_password, false)
    |> delete_change(:password)
  end

  defp hash_password(changeset), do: changeset
end

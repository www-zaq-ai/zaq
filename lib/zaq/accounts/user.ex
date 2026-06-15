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
    field :portal_consent, :string

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

  @doc """
  Creates a changeset for bootstrap onboarding (registration).

  Email and password are always required — registration is not valid without an
  email. Validates email format and uniqueness and hashes the password.
  """
  def bootstrap_onboarding_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password])
    |> validate_required([:email, :password])
    |> validate_email_format_and_uniqueness()
    |> PasswordPolicy.validate(:password)
    |> hash_password()
  end

  defp validate_email_format_and_uniqueness(changeset) do
    changeset
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email address"
    )
    |> unique_constraint(:email)
  end

  def portal_consent_changeset(user, consent)
      when consent in ["accepted", "declined"] do
    change(user, portal_consent: consent)
  end

  @doc """
  Changeset for the dashboard portal-activation (retry) flow.

  Records consent as accepted and, for older accounts with no email on file,
  captures and validates the email. The email format is validated here so an
  invalid address never reaches the portal. `Zaq.UserPortal.Onboarding.activate_portal/2`
  builds this changeset, validates it up front, and only persists it once
  provisioning succeeds — so a failed attempt never commits an email change.
  """
  def portal_activation_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :portal_consent])
    |> validate_required([:email, :portal_consent])
    |> validate_email_format_and_uniqueness()
  end

  defp hash_password(%{valid?: true, changes: %{password: password}} = changeset) do
    changeset
    |> put_change(:password_hash, Bcrypt.hash_pwd_salt(password))
    |> put_change(:must_change_password, false)
    |> delete_change(:password)
  end

  defp hash_password(changeset), do: changeset
end

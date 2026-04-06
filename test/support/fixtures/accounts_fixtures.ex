defmodule Zaq.AccountsFixtures do
  @moduledoc """
  Factories for `Zaq.Accounts` entities used in tests.
  """
  alias Zaq.Accounts
  alias Zaq.Accounts.Role
  alias Zaq.Repo

  def role_fixture(attrs \\ %{}) do
    name = Map.get(attrs, :name, "role_#{System.unique_integer([:positive])}")

    case Repo.get_by(Role, name: name) do
      %Role{} = role ->
        role

      nil ->
        {:ok, role} = Accounts.create_role(Enum.into(attrs, %{name: name, meta: %{}}))
        role
    end
  end

  def user_fixture(attrs \\ %{}) do
    role = attrs[:role] || role_fixture()

    {:ok, user} =
      attrs
      |> Map.drop([:role])
      |> Enum.into(%{
        username: "user_#{System.unique_integer([:positive])}",
        email: "user_#{System.unique_integer([:positive])}@example.com",
        role_id: role.id
      })
      |> Accounts.create_user()

    user
  end

  def super_admin_fixture(attrs \\ %{}) do
    role = role_fixture(%{name: "super_admin"})

    user_fixture(
      Map.merge(attrs, %{
        role: role,
        username: "super_admin_#{System.unique_integer([:positive])}"
      })
    )
  end

  def admin_fixture(attrs \\ %{}) do
    role = role_fixture(%{name: "admin"})

    user_fixture(
      Map.merge(attrs, %{role: role, username: "admin_#{System.unique_integer([:positive])}"})
    )
  end

  def staff_fixture(attrs \\ %{}) do
    role = role_fixture(%{name: "staff"})

    user_fixture(
      Map.merge(attrs, %{role: role, username: "staff_#{System.unique_integer([:positive])}"})
    )
  end
end

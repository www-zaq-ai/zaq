defmodule Zaq.Accounts.UserTest do
  use ExUnit.Case, async: true

  alias Zaq.Accounts.User

  test "changeset/2 validates required fields" do
    changeset = User.changeset(%User{}, %{})

    refute changeset.valid?
    assert "can't be blank" in errors_on(changeset).username
    assert "can't be blank" in errors_on(changeset).role_id
  end

  test "password_changeset/2 hashes password and clears virtual field" do
    changeset = User.password_changeset(%User{}, %{password: "StrongPass1!"})

    assert changeset.valid?
    assert get_change(changeset, :password) == nil
    assert get_change(changeset, :must_change_password) == false

    password_hash = get_change(changeset, :password_hash)
    assert is_binary(password_hash)
    assert Bcrypt.verify_pass("StrongPass1!", password_hash)
  end

  test "password_changeset/2 enforces minimum length" do
    changeset = User.password_changeset(%User{}, %{password: "short"})

    refute changeset.valid?
    assert "should be at least 8 character(s)" in errors_on(changeset).password
  end

  test "password_changeset/2 enforces character class requirements" do
    changeset = User.password_changeset(%User{}, %{password: "alllowercase1!"})

    refute changeset.valid?
    assert "must include at least one uppercase letter" in errors_on(changeset).password
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp get_change(changeset, field), do: Ecto.Changeset.get_change(changeset, field)
end

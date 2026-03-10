defmodule Zaq.Accounts.RoleTest do
  use ExUnit.Case, async: true

  alias Zaq.Accounts.Role

  test "changeset/2 requires name" do
    changeset = Role.changeset(%Role{}, %{})

    refute changeset.valid?
    assert "can't be blank" in errors_on(changeset).name
  end

  test "changeset/2 keeps provided meta" do
    changeset = Role.changeset(%Role{}, %{name: "manager", meta: %{"scope" => "all"}})

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :meta) == %{"scope" => "all"}
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end

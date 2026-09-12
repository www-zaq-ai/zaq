defmodule Zaq.Accounts.PersonEmailTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Accounts.{People, Person}

  test "both storage changesets canonicalize Unicode email and keep email optional" do
    for changeset <- [&Person.changeset/2, &Person.update_changeset/2] do
      for {input, expected} <- [
            {" \tÄLİCE@EXAMPLE.COM\u00A0", "äli̇ce@example.com"},
            {"", nil},
            {" \n\u2003", nil},
            {nil, nil}
          ] do
        result = changeset.(%Person{}, %{full_name: "Alice", email: input})
        assert result.valid?
        assert get_field(result, :email) == expected
      end

      person = %Person{full_name: "Alice", email: "alice@example.com", phone: "123"}
      assert get_field(changeset.(person, %{role: "Engineer"}), :email) == person.email
      refute get_field(changeset.(person, %{}), :incomplete)
      assert get_field(changeset.(person, %{email: "  "}), :incomplete)
      refute changeset.(person, %{email: 123}).valid?
    end
  end

  property "canonical storage is idempotent and independent of ASCII case and boundary whitespace" do
    check all(
            local <- string(:alphanumeric, min_length: 1, max_length: 40),
            padding <- member_of(["", " ", "\t\n", "\u00A0", "\u2003"])
          ) do
      canonical = String.downcase(local) <> "@example.com"
      attrs = %{full_name: "Person", email: padding <> String.upcase(canonical) <> padding}
      person = %Person{} |> Person.changeset(attrs) |> apply_changes()
      assert person.email == canonical

      assert person |> Person.update_changeset(%{email: person.email}) |> get_field(:email) ==
               canonical
    end
  end

  test "incoming creates and updates reject case-equivalent duplicates without merging" do
    assert {:ok, first} =
             People.create_person(%{full_name: "First", email: " FIRST@Example.COM "})

    assert first.email == "first@example.com"

    assert {:ok, second} =
             People.create_person(%{full_name: "Second", email: "second@example.com"})

    assert {:error, create_error} =
             People.create_person(%{full_name: "Duplicate", email: "First@EXAMPLE.com"})

    assert errors_on(create_error).email == ["has already been taken"]
    assert {:error, update_error} = People.update_person(second, %{email: " FIRST@example.com "})
    assert errors_on(update_error).email == ["has already been taken"]
    assert People.get_person!(second.id).email == "second@example.com"
    assert {:ok, same} = People.update_person(first, %{email: "First@Example.com"})
    assert same.id == first.id
    assert length(People.list_people()) == 2
  end

  test "email matching and channel discovery use the storage canonical form" do
    {:ok, person} = People.create_person(%{full_name: "Alice", email: "äli̇ce@example.com"})
    assert {:ok, %{id: id}} = People.match_person(%{"email" => " ÄLİCE@Example.COM "})
    assert id == person.id

    assert {:ok, found} =
             People.find_or_create_from_channel(:slack, %{
               "email" => " ÄLİCE@Example.COM ",
               "channel_id" => "alice-slack"
             })

    assert found.id == person.id
    assert length(People.list_people()) == 1
    assert Enum.count(found.channels, &(&1.platform == "email")) == 1
    assert {:error, :not_found} = People.match_person(%{"email" => " \t"})
    assert {:error, :not_found} = People.match_person(%{"email" => nil})
  end

  test "channel discovery normalizes new partial identities and backfills existing ones" do
    assert {:ok, partial} =
             People.find_or_create_from_channel(:slack, %{
               channel_id: "partial-slack",
               email: " PARTIAL@Example.com "
             })

    assert partial.email == "partial@example.com"
    assert {:ok, found} = People.match_person(%{email: "PARTIAL@example.com"})
    assert found.id == partial.id

    assert {:ok, blank} =
             People.find_or_create_from_channel(:slack, %{
               channel_id: "blank-slack",
               email: " \t"
             })

    assert blank.email == nil
    assert length(blank.channels) == 1

    assert {:ok, filled} =
             People.find_or_create_from_channel(:slack, %{
               channel_id: "blank-slack",
               email: " FILLED@Example.com "
             })

    assert filled.id == blank.id
    assert filled.email == "filled@example.com"

    assert {:error, changeset} =
             People.find_or_create_from_channel(:slack, %{
               channel_id: "invalid-slack",
               email: 123
             })

    assert errors_on(changeset).email == ["is invalid"]
  end
end

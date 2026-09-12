defmodule Zaq.Accounts.PeopleSelectionTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties
  alias Zaq.Accounts.{People, Person, PersonChannel}
  alias Zaq.Engine.PeopleGateway

  property "invalid ID values reject the whole selection in both modes" do
    check all(
            invalid <-
              one_of([
                integer(-1000..0),
                string(:alphanumeric),
                constant(nil),
                integer(9_223_372_036_854_775_808..9_223_372_036_854_775_999)
              ]),
            mode <- member_of([:explicit, :all_matching])
          ) do
      assert {:error, :invalid_selection} =
               People.resolve_selection(%{mode: mode, filters: %{}, ids: [1, invalid]})
    end
  end

  test "resolution shares combined literal filters and stable pagination ordering" do
    {:ok, team} = People.create_team(%{name: "Selection team"})

    attrs = %{
      full_name: "Same %_\\ name",
      email: "literal%_@example.com",
      phone: "123%_",
      incomplete: false,
      team_ids: [team.id]
    }

    first = Repo.insert!(struct(Person, attrs))
    second = Repo.insert!(struct(Person, %{attrs | email: "second%_@example.com"}))

    for override <- [
          %{full_name: "Other"},
          %{email: "other@example.com"},
          %{phone: "other"},
          %{incomplete: true},
          %{team_ids: []}
        ] do
      unique = Map.put(attrs, :email, "#{System.unique_integer([:positive])}%_@example.com")
      Repo.insert!(struct(Person, Map.merge(unique, override)))
    end

    filters = %{
      "name" => "%_\\",
      "email" => "%_",
      "phone" => "%_",
      "complete" => "complete",
      "team_id" => to_string(team.id)
    }

    assert {:ok, [a, b]} = resolve(filters)
    assert [a, b] == [first.id, second.id]
    assert {[row], 2} = People.filter_people(filters, page: 2, per_page: 1)
    assert row.id == second.id
    assert {:ok, [^b]} = resolve(filters, [a])

    assert {:ok, [^a]} =
             People.resolve_selection(%{mode: :explicit, filters: filters, ids: [a, a]})

    assert {:ok, []} = resolve(%{"name" => "no match"})
  end

  test "unfiltered resolution is explicit and snapshot excludes later arrivals" do
    person = Repo.insert!(%Person{full_name: "Before"})

    channel =
      Repo.insert!(%PersonChannel{
        person_id: person.id,
        platform: "slack",
        channel_identifier: "before"
      })

    assert {:ok, ids} = resolve(%{})
    assert person.id in ids
    later = Repo.insert!(%Person{full_name: "After"})

    assert {:ok, %{deleted_count: count, failed_ids: []}} =
             PeopleGateway.dispatch(:bulk_delete, %{person_ids: ids})

    assert count == length(ids)
    assert People.get_person(later.id)
    refute Repo.get(PersonChannel, channel.id)
  end

  test "missing snapshot member rolls back all deletes and cascades" do
    person = Repo.insert!(%Person{full_name: "Rollback"})

    channel =
      Repo.insert!(%PersonChannel{
        person_id: person.id,
        platform: "slack",
        channel_identifier: "rollback"
      })

    missing = person.id + 1_000_000

    assert {:ok, %{deleted_count: 0, failed_ids: [^missing]}} =
             People.bulk_delete_people([person.id, missing])

    assert People.get_person(person.id)
    assert Repo.get(PersonChannel, channel.id)
  end

  test "malformed selections never widen to all records or partially delete" do
    assert {:error, :invalid_selection} = resolve(%Person{})
    assert {:error, :invalid_selection} = resolve(%{"team_id" => "9223372036854775808"})

    for request <- [
          nil,
          %{},
          %{mode: :all_matching, ids: []},
          %{mode: :unknown, filters: %{}, ids: []},
          %{mode: :all_matching, filters: %{"name" => nil}, ids: []},
          %{mode: :all_matching, filters: %{"team_id" => "oops"}, ids: []},
          %{mode: :all_matching, filters: %{"complete" => "oops"}, ids: []},
          %{mode: :all_matching, filters: %{"typo" => "x"}, ids: []},
          %{mode: :all_matching, filters: %{}, ids: ["oops"]},
          %{mode: :all_matching, filters: %{}, ids: [-1]},
          %{mode: :all_matching, filters: %{}, ids: nil}
        ] do
      assert {:error, :invalid_selection} = PeopleGateway.dispatch(:resolve_selection, request)
    end

    person = Repo.insert!(%Person{full_name: "Safe"})

    for ids <- [[person.id, "bad"], nil, [0], [-1]] do
      assert {:error, :invalid_person_ids} = People.bulk_delete_people(ids)
    end

    assert People.get_person(person.id)
    assert {:ok, %{deleted_count: 0}} = People.bulk_delete_people([])
  end

  defp resolve(filters, exclusions \\ []) do
    PeopleGateway.dispatch(:resolve_selection, %{
      mode: :all_matching,
      filters: filters,
      ids: exclusions
    })
  end
end

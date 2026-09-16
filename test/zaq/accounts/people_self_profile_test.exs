defmodule Zaq.Accounts.PeopleSelfProfileTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Accounts.{People, Person, PersonChannel}

  setup do
    {:ok, person} =
      People.create_person(%{
        full_name: "Original",
        email: "self@example.test",
        phone: "123",
        role: "Engineer",
        metadata: %{"private" => true}
      })

    [channel] = People.list_person_channels(person.id)
    %{person: person, channel: channel}
  end

  property "self profile accepts only full_name and derived completeness", %{person: person} do
    check all(name <- string(:alphanumeric, min_length: 1, max_length: 60)) do
      attrs = %{
        full_name: name,
        email: "other@example.test",
        phone: "456",
        role: "Admin",
        status: "inactive",
        team_ids: [99],
        metadata: %{},
        merged_person_ids: [99],
        merge_history: [],
        incomplete: true
      }

      assert {:ok, updated} = People.update_self_profile(person, attrs)
      assert updated.full_name == name
      refute updated.incomplete

      assert Map.drop(Map.from_struct(updated), [:full_name, :updated_at]) ==
               Map.drop(Map.from_struct(person), [:full_name, :updated_at])
    end
  end

  test "blank remains optional and invalid types fail without persistence", %{person: person} do
    for value <- [123, %{}, []] do
      assert {:error, changeset} = People.update_self_profile(person, %{"full_name" => value})
      assert errors_on(changeset).full_name == ["is invalid"]
      assert People.get_person(person.id).full_name == "Original"
    end

    assert {:ok, blank} = People.update_self_profile(person, %{"full_name" => " "})
    assert blank.full_name == ""
    assert blank.incomplete
    assert {:error, :not_found} = People.update_self_profile(nil, %{})
    assert {:error, :not_found} = People.update_self_profile(%Person{}, %{})
  end

  test "owned priority changes preserve all identity, metadata and activity fields", %{
    person: p,
    channel: c
  } do
    assert {:ok, updated} =
             People.update_self_channel_weight(p, Integer.to_string(c.id), %{
               "weight" => "17",
               "person_id" => 99,
               "platform" => "slack",
               "channel_identifier" => "stolen",
               "metadata" => %{"bad" => true},
               "last_interaction_at" => DateTime.utc_now()
             })

    assert updated.weight == 17

    assert Map.drop(Map.from_struct(updated), [:weight, :updated_at]) ==
             Map.drop(Map.from_struct(c), [:weight, :updated_at])

    {:ok, other} = People.create_person(%{full_name: "Other"})

    for {owner, id} <- [
          {other, c.id},
          {p, -1},
          {p, "junk"},
          {p, nil},
          {nil, c.id},
          {%Person{}, c.id}
        ] do
      assert {:error, :not_found} = People.update_self_channel_weight(owner, id, %{weight: 1})
    end

    assert People.get_channel(c.id).weight == 17
  end

  test "priority validates integers and nonnegative values and sorts ties by id", %{
    person: p,
    channel: c
  } do
    for weight <- [-1, "-1", "1.5", 1.5, "junk", nil, 2_147_483_648, String.duplicate("9", 80)] do
      assert {:error, changeset} = People.update_self_channel_weight(p, c.id, %{weight: weight})
      assert errors_on(changeset).weight != []
      assert People.get_channel(c.id).weight == 0
    end

    {:ok, second} =
      People.add_channel(%{person_id: p.id, platform: "slack", channel_identifier: "second"})

    assert {:ok, _} = People.update_self_channel_weight(p, c.id, %{weight: 2_147_483_647})
    assert [second.id, c.id] == Enum.map(People.list_person_channels(p.id), & &1.id)
    assert {:ok, _} = People.update_self_channel_weight(p, c.id, %{weight: second.weight})
    assert [c.id, second.id] == Enum.map(People.list_person_channels(p.id), & &1.id)
    assert People.get_preferred_channel(p.id).id == c.id
  end

  property "weight changeset ignores every non-weight schema field", %{channel: c} do
    check all(weight <- integer(0..10_000)) do
      attrs =
        Map.from_struct(c)
        |> Map.put(:weight, weight)
        |> Map.put(:platform, "unknown")
        |> Map.put(:person_id, 999)

      changeset = PersonChannel.weight_changeset(c, attrs)
      assert changeset.valid?
      assert Map.keys(changeset.changes) -- [:weight] == []
    end
  end
end

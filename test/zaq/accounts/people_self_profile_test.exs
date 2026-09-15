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

  test "atomic order validates the complete snapshot and permutation without partial writes", %{
    person: p,
    channel: c
  } do
    {:ok, b} =
      People.add_channel(%{
        person_id: p.id,
        platform: "slack",
        channel_identifier: "order-second"
      })

    {:ok, other} =
      People.create_person(%{full_name: "Foreign", email: "foreign-order@example.test"})

    [foreign] = People.list_person_channels(other.id)
    original = People.list_person_channels(p.id)
    expected = Enum.map(original, &Map.take(&1, [:id, :weight]))

    for ids <- [
          [c.id],
          [c.id, c.id],
          [c.id, foreign.id],
          [c.id, b.id, foreign.id],
          nil,
          %{},
          ["bad"],
          [c.id | :bad]
        ] do
      assert {:error, :invalid_order} = People.update_self_channel_order(p, ids, expected)
      assert People.list_person_channels(p.id) == original
    end

    assert {:error, :not_found} = People.update_self_channel_order(nil, [], [])

    assert {:error, :invalid_order} =
             People.update_self_channel_order(p, [b.id, c.id], [%{id: c.id, weight: nil}])

    assert {:ok, ordered} = People.update_self_channel_order(p, [b.id, c.id], expected)
    assert Enum.map(ordered, &{&1.id, &1.weight}) == [{b.id, 0}, {c.id, 1}]

    for channel <- ordered do
      before = Enum.find(original, &(&1.id == channel.id))

      assert Map.drop(Map.from_struct(channel), [:weight, :updated_at]) ==
               Map.drop(Map.from_struct(before), [:weight, :updated_at])
    end

    assert {:error, :stale_order} = People.update_self_channel_order(p, [c.id, b.id], expected)
    assert People.get_channel(foreign.id) == foreign
  end

  test "membership, weight-only changes and outer rollback protect an order draft", %{
    person: p,
    channel: c
  } do
    expected = [%{id: c.id, weight: c.weight}]
    {:ok, _} = People.update_self_channel_weight(p, c.id, %{weight: 8})
    assert {:error, :stale_order} = People.update_self_channel_order(p, [c.id], expected)
    expected = [%{id: c.id, weight: 8}]

    assert {:error, :abort} =
             Repo.transaction(fn ->
               assert {:ok, _} = People.update_self_channel_order(p, [c.id], expected)
               Repo.rollback(:abort)
             end)

    assert People.get_channel(c.id).weight == 8

    {:ok, b} =
      People.add_channel(%{person_id: p.id, platform: "slack", channel_identifier: "membership"})

    assert {:error, :stale_order} = People.update_self_channel_order(p, [c.id], expected)
    expected = Enum.map(People.list_person_channels(p.id), &Map.take(&1, [:id, :weight]))
    {:ok, _} = People.delete_channel(b)
    assert {:error, :stale_order} = People.update_self_channel_order(p, [c.id, b.id], expected)
  end

  property "full permutations persist in exactly requested order with dense bounded weights", %{
    person: p
  } do
    for index <- 1..3 do
      {:ok, _} =
        People.add_channel(%{
          person_id: p.id,
          platform: "slack",
          channel_identifier: "permutation-#{index}"
        })
    end

    ids = Enum.map(People.list_person_channels(p.id), & &1.id)

    check all(priorities <- list_of(integer(), length: 4)) do
      ordered = Enum.zip(ids, priorities) |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))
      expected = Enum.map(People.list_person_channels(p.id), &Map.take(&1, [:id, :weight]))
      assert {:ok, rows} = People.update_self_channel_order(p, ordered, expected)
      assert Enum.map(rows, & &1.id) == ordered
      assert Enum.map(People.list_person_channels(p.id), & &1.id) == ordered
      assert Enum.map(rows, & &1.weight) == [0, 1, 2, 3]
    end
  end
end

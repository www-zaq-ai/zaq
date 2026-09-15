defmodule ZaqWeb.ChannelOrderTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias ZaqWeb.ChannelOrder

  property "moves preserve every row and the relative order of all other rows" do
    check all(
            ids <- uniq_list_of(integer(1..100_000), min_length: 1, max_length: 30),
            source <- integer(0..100),
            target <- integer(0..100)
          ) do
      rows = Enum.map(ids, &%{id: to_string(&1), value: &1})
      id = Enum.at(rows, rem(source, length(rows))).id
      destination = Enum.at(rows, rem(target, length(rows))).id
      moved = ChannelOrder.move(rows, id, destination)
      assert Enum.sort(moved) == Enum.sort(rows)
      assert Enum.reject(moved, &(&1.id == id)) == Enum.reject(rows, &(&1.id == id))
      assert Enum.find_index(moved, &(&1.id == id)) == rem(target, length(rows))
      assert ChannelOrder.move(rows, "missing", "up") == rows
      assert ChannelOrder.move(rows, id, %{}) == rows
    end
  end

  test "one-step moves and boundaries" do
    rows = [%{id: "a"}, %{id: "b"}]
    assert ChannelOrder.move(rows, "a", "up") == rows
    assert ChannelOrder.move(rows, "b", "down") == rows
    assert ChannelOrder.move(rows, "a", "down") == Enum.reverse(rows)
    assert ChannelOrder.move(rows, "b", "up") == Enum.reverse(rows)
    assert ChannelOrder.move([], "a", "up") == []

    assert ChannelOrder.announcement([%{id: "a", platform: "Email", identifier: "me"}], "a") ==
             "Email, me, moved to position 1 of 1."
  end
end

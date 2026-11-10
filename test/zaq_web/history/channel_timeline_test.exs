defmodule ZaqWeb.History.ChannelTimelineTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ZaqWeb.History.ChannelTimeline

  property "duplicate and reordered hints cannot duplicate a current canonical answer" do
    check all(
            ids <-
              uniq_list_of(string(:alphanumeric, min_length: 1), min_length: 1, max_length: 20)
          ) do
      rows =
        Enum.with_index(ids, 1)
        |> Enum.map(fn {id, position} -> %{message_id: id, position: position} end)

      pending = Enum.map(rows, &Map.put(&1, :position, nil))
      detail = %{messages: [], pending_messages: pending, has_more: false, next_cursor: 0}
      changes = %{messages: Enum.reverse(rows), pending_messages: [], removed_ids: []}

      result = ChannelTimeline.merge_changes(detail, changes, 0)
      assert result.pending_messages == []
      assert Enum.map(result.messages, & &1.message_id) == ids
      assert ChannelTimeline.merge_changes(result, changes, 0) == result
    end
  end

  test "an earlier canonical page never borrows pending IDs for its cursor" do
    detail = %{
      messages: [%{message_id: "input", position: 1}],
      pending_messages: [%{message_id: "answer", position: nil}],
      has_more: true,
      next_cursor: 1
    }

    changes = %{
      messages: [%{message_id: "answer", position: 52}],
      pending_messages: [],
      removed_ids: []
    }

    merged = ChannelTimeline.merge_changes(detail, changes, 0)
    assert merged.next_cursor == 1
    assert merged.messages == detail.messages
    assert merged.pending_messages == []
  end
end

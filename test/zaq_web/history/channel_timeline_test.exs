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

  property "off-page hint bursts never load outstanding pages implicitly" do
    check all(ids <- list_of(integer(51..1000), min_length: 1, max_length: 150)) do
      initial = pending_detail(1..50, true)

      merged =
        ids
        |> Enum.map(&pending_row/1)
        |> Enum.chunk_every(50)
        |> Enum.reduce(initial, fn rows, detail ->
          ChannelTimeline.merge_changes(detail, changes(rows), 0)
        end)

      assert merged.pending_messages == initial.pending_messages
      assert merged.pending_next_cursor == "after-50"
      assert merged.pending_has_more
      assert merged.next_cursor == 0
    end
  end

  test "new pending rows fill available capacity and leave overflow behind load-more" do
    initial = pending_detail(1..49, false)
    update = changes([pending_row(51), pending_row(50)])
    merged = ChannelTimeline.merge_changes(initial, update, 0)

    assert merged.pending_messages == Enum.map(1..50, &pending_row/1)
    assert merged.pending_next_cursor == "after-49"
    assert merged.pending_has_more
    assert ChannelTimeline.merge_changes(merged, update, 0) == merged

    page = pending_page([pending_row(50), pending_row(51)], false)
    loaded = ChannelTimeline.append_pending_page(merged, page)
    assert loaded.pending_messages == Enum.map(1..51, &pending_row/1)
    refute loaded.pending_has_more
  end

  test "new tail hints never advance continuation past rows whose notifications were lost" do
    initial = pending_detail(1..49, false)

    merged =
      ChannelTimeline.merge_changes(initial, changes([pending_row(100), pending_row(101)]), 0)

    assert length(merged.pending_messages) == 50
    assert List.last(merged.pending_messages).message_id == "pending-100"
    assert merged.pending_next_cursor == "after-49"
    assert merged.pending_has_more

    changed = %{pending_row(100) | pending_cursor: "after-100"}

    assert ChannelTimeline.merge_changes(merged, changes([changed]), 0).pending_messages ==
             merged.pending_messages

    loaded =
      ChannelTimeline.append_pending_page(
        merged,
        pending_page(Enum.map(50..99, &pending_row/1), true)
      )

    assert loaded.pending_messages == Enum.map(1..100, &pending_row/1)
    assert loaded.pending_next_cursor == "after-99"
  end

  test "an older newly eligible row rewinds continuation rather than skipping the evicted row" do
    initial = pending_detail(1..50, true)
    merged = ChannelTimeline.merge_changes(initial, changes([pending_row(0)]), 0)

    assert merged.pending_messages == Enum.map(0..49, &pending_row/1)
    assert merged.pending_next_cursor == "after-49"
    assert merged.pending_has_more

    loaded =
      ChannelTimeline.append_pending_page(
        merged,
        pending_page(Enum.map(50..99, &pending_row/1), true)
      )

    assert loaded.pending_messages == Enum.map(0..99, &pending_row/1)
    assert loaded.pending_next_cursor == "after-99"
  end

  test "removing the boundary row preserves the loaded window until explicit load-more" do
    initial = pending_detail(1..50, true)

    merged =
      ChannelTimeline.merge_changes(initial, %{changes([]) | removed_ids: ["pending-50"]}, 0)

    merged = ChannelTimeline.merge_changes(merged, changes([pending_row(51)]), 0)

    assert merged.pending_messages == Enum.map(1..49, &pending_row/1)
    assert merged.pending_next_cursor == "after-50"
    assert merged.pending_has_more

    loaded =
      ChannelTimeline.append_pending_page(
        merged,
        pending_page(Enum.map(51..100, &pending_row/1), true)
      )

    assert length(loaded.pending_messages) == 99
    assert loaded.pending_next_cursor == "after-100"
    assert loaded.pending_has_more
  end

  test "an empty pending page retains continuation after outstanding rows disappear" do
    initial = pending_detail(1..50, true)
    update = %{changes([]) | removed_ids: Enum.map(initial.pending_messages, & &1.message_id)}
    merged = ChannelTimeline.merge_changes(initial, update, 0)
    loaded = ChannelTimeline.append_pending_page(merged, pending_page([], false))

    assert loaded.pending_messages == []
    assert loaded.pending_next_cursor == "after-50"
    refute loaded.pending_has_more

    updated = ChannelTimeline.merge_changes(loaded, changes([pending_row(51)]), 0)
    assert updated.pending_messages == [pending_row(51)]
  end

  defp pending_detail(indices, has_more) do
    rows = Enum.map(indices, &pending_row/1)

    %{
      messages: [],
      pending_messages: rows,
      next_cursor: 0,
      has_more: false,
      pending_next_cursor: List.last(rows).pending_cursor,
      pending_has_more: has_more
    }
  end

  defp pending_row(index) do
    %{
      message_id: "pending-#{index}",
      position: nil,
      inserted_at: DateTime.add(~U[2026-11-10 10:30:00.000000Z], index, :microsecond),
      pending_cursor: "after-#{index}"
    }
  end

  defp pending_page(rows, has_more) do
    %{
      pending_messages: rows,
      pending_next_cursor: if(rows != [], do: List.last(rows).pending_cursor),
      pending_has_more: has_more
    }
  end

  defp changes(rows), do: %{messages: [], pending_messages: rows, removed_ids: []}
end

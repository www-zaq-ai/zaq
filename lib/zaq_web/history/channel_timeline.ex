defmodule ZaqWeb.History.ChannelTimeline do
  @moduledoc """
  Pure merging of authorized channel-history row updates into the current BO page.

  Canonical positions own pagination; provisional rows remain at the bottom and
  sort by recorded generation time within the explicitly loaded capacity. Pending
  continuation tokens come from Engine and remain opaque here. No persistence or
  notification handling lives here; a missing response never implies deletion.
  """

  @page_size 50

  @doc "Applies an authoritative bounded reread without replacing unaffected rows."
  def merge_changes(detail, changes, cursor) do
    changed_ids =
      Enum.map(changes.messages ++ changes.pending_messages, & &1.message_id) ++
        changes.removed_ids

    canonical =
      reject_ids(detail.messages, changed_ids)
      |> Kernel.++(Enum.filter(changes.messages, &in_window?(&1, detail, cursor)))
      |> Enum.uniq_by(& &1.message_id)
      |> Enum.sort_by(& &1.position)

    displayed = Enum.take(canonical, @page_size)

    %{
      detail
      | messages: displayed,
        next_cursor: last_position(displayed, cursor),
        has_more: detail.has_more or length(canonical) > @page_size
    }
    |> Map.merge(merge_pending(detail, changes.pending_messages, changed_ids))
  end

  @doc "Adds an explicitly requested pending page without changing canonical cursors."
  def append_pending_page(detail, page) do
    Map.merge(detail, %{
      pending_messages: sort_pending(page.pending_messages ++ detail.pending_messages),
      pending_next_cursor: page.pending_next_cursor || detail.pending_next_cursor,
      pending_has_more: page.pending_has_more,
      pending_limit: Map.get(detail, :pending_limit, @page_size) + @page_size,
      pending_window_end:
        pending_key(List.last(page.pending_messages)) || pending_window_end(detail)
    })
  end

  defp merge_pending(detail, rows, changed_ids) do
    limit = Map.get(detail, :pending_limit, @page_size)
    window_end = pending_window_end(detail)
    has_more = Map.get(detail, :pending_has_more, false)
    loaded_ids = MapSet.new(detail.pending_messages, & &1.message_id)

    in_window =
      Enum.filter(rows, fn row ->
        not has_more or in_pending_window?(row, loaded_ids, window_end)
      end)

    pending =
      reject_ids(detail.pending_messages, changed_ids)
      |> Kernel.++(in_window)
      |> sort_pending()

    displayed = Enum.take(pending, limit)
    last = List.last(displayed)
    overflow = length(pending) > limit

    # Rewind when an older eligible answer displaces a row beyond the loaded limit.
    # Hints never advance it: skipped notifications may hide rows before a new tail.
    rewind_boundary = overflow and not is_nil(window_end) and pending_key(last) < window_end

    %{
      pending_messages: displayed,
      pending_limit: limit,
      pending_window_end: if(rewind_boundary, do: pending_key(last), else: window_end),
      pending_next_cursor:
        if(rewind_boundary,
          do: last.pending_cursor,
          else: Map.get(detail, :pending_next_cursor)
        ),
      pending_has_more: has_more or overflow or length(in_window) < length(rows)
    }
  end

  defp in_pending_window?(row, loaded_ids, window_end),
    do:
      MapSet.member?(loaded_ids, row.message_id) or
        (not is_nil(window_end) and pending_key(row) <= window_end)

  defp pending_window_end(detail),
    do: Map.get(detail, :pending_window_end, pending_key(List.last(detail.pending_messages)))

  defp pending_key(%{inserted_at: time, message_id: id}),
    do: {DateTime.to_unix(time, :microsecond), id}

  defp pending_key(_row), do: nil

  defp in_window?(row, detail, cursor),
    do: row.position > cursor and (not detail.has_more or row.position <= detail.next_cursor)

  defp reject_ids(rows, ids) do
    ids = MapSet.new(ids)
    Enum.reject(rows, &MapSet.member?(ids, &1.message_id))
  end

  defp sort_pending(rows) do
    rows
    |> Enum.uniq_by(& &1.message_id)
    |> Enum.sort_by(&pending_key/1)
  end

  defp last_position([], cursor), do: cursor
  defp last_position(rows, _cursor), do: List.last(rows).position
end

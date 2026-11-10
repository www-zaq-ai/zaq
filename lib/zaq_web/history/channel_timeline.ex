defmodule ZaqWeb.History.ChannelTimeline do
  @moduledoc """
  Pure merging of authorized channel-history row updates into the current BO page.

  Canonical positions own pagination; provisional rows remain at the bottom and
  sort by recorded generation time. No persistence or notification handling lives
  here, and a missing response is never interpreted as a deletion.
  """

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

    pending =
      reject_ids(detail.pending_messages, changed_ids)
      |> Kernel.++(changes.pending_messages)
      |> sort_pending()

    displayed = Enum.take(canonical, 50)

    %{
      detail
      | messages: displayed,
        pending_messages: pending,
        next_cursor: last_position(displayed, cursor),
        has_more: detail.has_more or length(canonical) > 50
    }
  end

  @doc "Adds an explicitly requested pending page without changing canonical cursors."
  def append_pending_page(detail, page) do
    %{
      detail
      | pending_messages: sort_pending(detail.pending_messages ++ page.pending_messages),
        pending_next_cursor: page.pending_next_cursor,
        pending_has_more: page.pending_has_more
    }
  end

  defp in_window?(row, detail, cursor),
    do: row.position > cursor and (not detail.has_more or row.position <= detail.next_cursor)

  defp reject_ids(rows, ids), do: Enum.reject(rows, &(&1.message_id in ids))

  defp sort_pending(rows) do
    rows
    |> Enum.uniq_by(& &1.message_id)
    |> Enum.sort_by(&{DateTime.to_unix(&1.inserted_at, :microsecond), &1.message_id})
  end

  defp last_position([], cursor), do: cursor
  defp last_position(rows, _cursor), do: List.last(rows).position
end

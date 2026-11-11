defmodule Zaq.Engine.ChannelHistoryPending do
  @moduledoc """
  Bounded provisional answer rows for an already-authorized BO transcript read.

  Exact input placements and completed answer ownership establish origin scope.
  Confirmed answers use the immutable target transcript set. This projection is
  read-only and never changes canonical history, permissions or delivery state.
  """

  import Ecto.Query

  alias Zaq.Contracts.Record
  alias Zaq.Engine.Conversations.{Message, MessageDelivery, TranscriptMessage}
  alias Zaq.Repo

  @page_size 50

  @doc "Reads one generation-ordered pending page independently of canonical positions."
  def page(transcript_id, cursor) do
    with {:ok, after_key} <- decode_cursor(cursor) do
      rows =
        candidates(transcript_id)
        |> after_cursor(after_key)
        |> order_by([a], asc: a.inserted_at, asc: a.id)
        |> limit(^(@page_size + 1))
        |> Repo.all()

      page = Enum.take(rows, @page_size)

      {:ok,
       %{
         rows: Enum.map(page, &present/1),
         has_more: length(rows) > @page_size,
         next_cursor: encode_cursor(List.last(page))
       }}
    end
  end

  @doc "Reads only affected IDs; the owning admin operation must authorize the transcript."
  def by_ids(transcript_id, ids) do
    candidates(transcript_id)
    |> where([a], a.id in ^ids)
    |> order_by([a], asc: a.inserted_at, asc: a.id)
    |> Repo.all()
    |> Enum.map(&present/1)
  end

  @doc "Finds an exact provisional answer for the explicitly privileged information read."
  def inspection_message(transcript_id, message_id) do
    candidates(transcript_id)
    |> where([a], a.id == ^message_id)
    |> Repo.one()
  end

  defp candidates(id) do
    targets = [id]

    origin =
      MessageDelivery.origin_query(id)
      |> where(
        [answer: a],
        is_nil(fragment("?->'delivery_confirmation'", a.metadata)) or
          fragment("?->'history_association'->'transcript_ids' @> ?::jsonb", a.metadata, ^targets)
      )
      |> select([answer: a], a.id)

    confirmed =
      MessageDelivery.answers_query()
      |> where(
        [answer: a],
        not is_nil(fragment("?->'delivery_confirmation'", a.metadata)) and
          fragment("?->'history_association'->'transcript_ids' @> ?::jsonb", a.metadata, ^targets)
      )
      |> select([answer: a], a.id)

    eligible = union(origin, ^confirmed)

    from a in Message,
      left_join: placement in TranscriptMessage,
      on: placement.message_id == a.id and placement.transcript_id == ^id,
      where: a.id in subquery(eligible) and is_nil(placement.message_id)
  end

  defp present(message) do
    %{
      message_id: message.id,
      position: nil,
      role: "assistant",
      content: message.content,
      inserted_at: message.inserted_at,
      attachments: Enum.map(message.attachments || [], &Record.attachment_metadata/1),
      pending_cursor: encode_cursor(message),
      delivery: MessageDelivery.presentation(message)
    }
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {time, id}) do
    where(query, [a], a.inserted_at > ^time or (a.inserted_at == ^time and a.id > ^id))
  end

  defp encode_cursor(nil), do: nil

  defp encode_cursor(message) do
    [DateTime.to_iso8601(message.inserted_at), message.id]
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(cursor) when is_binary(cursor) and byte_size(cursor) <= 512 do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         {:ok, [time, id]} when is_binary(time) <- Jason.decode(decoded),
         {:ok, time, 0} <- DateTime.from_iso8601(time),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {time, id}}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp decode_cursor(_cursor), do: {:error, :invalid_request}
end

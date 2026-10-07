defmodule Zaq.Engine.ChannelHistoryProjection do
  @moduledoc """
  Engine-local, page-bounded read model for authorized BO history lists.

  The caller supplies already scoped transcript rows. This module batches all
  participant, title, thread and locally stored root data for that finite page;
  it never dispatches provider requests.
  """

  import Ecto.Query

  alias Zaq.Accounts.{Person, PersonChannel}
  alias Zaq.Engine.Conversations.{Message, MessageRating, Transcript, TranscriptMessage}
  alias Zaq.Repo

  @doc "Projects one bounded transcript page without provider I/O."
  @spec project([map()]) :: [map()]
  def project([]), do: []

  def project(rows) when is_list(rows) do
    ids = Enum.map(rows, & &1.id)
    first_messages = first_messages(ids)
    roots = stored_roots(rows)

    people =
      rows
      |> Enum.map(& &1.owner_person_id)
      |> Kernel.++(Enum.map(Map.values(first_messages), &author_person_id/1))
      |> Kernel.++(Enum.map(Map.values(roots), &author_person_id/1))
      |> person_summaries()

    participants = participant_projection(rows)
    thread_counts = thread_counts(ids)
    identities = root_identities(rows, roots)
    ratings = rating_summaries(Enum.map(Map.values(roots), & &1.id))

    Enum.map(rows, fn row ->
      participant = Map.get(participants, row.id, %{recent: [], count: 0})
      root = Map.get(roots, row.id)

      Map.merge(row, %{
        owner: Map.get(people, row.owner_person_id),
        channel_name: history_title(Map.get(first_messages, row.id), row.channel_name, people),
        participants: participant.recent,
        participant_count: participant.count,
        thread_count: Map.get(thread_counts, row.id, 0),
        root_message: display_root(root, row, people, identities, ratings)
      })
    end)
  end

  defp participant_projection(rows) do
    request =
      Jason.encode!(
        Enum.map(rows, &%{id: &1.id, parent_id: &1.parent_id, thread_id: &1.thread_id})
      )

    requested =
      from row in fragment(
             "SELECT * FROM jsonb_to_recordset(?::text::jsonb) AS row(id uuid, parent_id uuid, thread_id text)",
             ^request
           ),
           select: %{id: row.id, parent_id: row.parent_id, thread_id: row.thread_id}

    scope = participant_message_scope()

    resolved =
      from requested in "requested",
        as: :requested,
        join: transcript in Transcript,
        as: :transcript,
        on:
          transcript.id == requested.id or transcript.parent_id == requested.id or
            transcript.id == requested.parent_id,
        join: placement in TranscriptMessage,
        on: placement.transcript_id == transcript.id,
        join: message in Message,
        as: :message,
        on: message.id == placement.message_id,
        left_join: identity in PersonChannel,
        on:
          identity.channel_config_id == transcript.channel_config_id and
            is_nil(fragment("?->>'author_person_id'", message.history_context)) and
            identity.platform ==
              coalesce(
                fragment("?->>'identity_platform'", message.history_context),
                transcript.provider
              ) and
            identity.channel_identifier == message.author_id,
        join: person in Person,
        on:
          person.id == identity.person_id or
            fragment(
              """
              EXISTS (
                SELECT 1
                FROM jsonb_array_elements(COALESCE(?->'participants', '[]'::jsonb)) participant
                WHERE (participant->>'person_id')::bigint = ANY(array_prepend(?, ?))
              )
              """,
              message.history_context,
              person.id,
              person.merged_person_ids
            ),
        where: message.role != "assistant",
        where: ^scope,
        group_by: [requested.id, person.id, person.full_name],
        select: %{
          requested_id: requested.id,
          person_id: person.id,
          display_name: person.full_name,
          last_seen: max(coalesce(message.provider_sent_at, message.inserted_at))
        }

    ranked =
      from resolved in "resolved",
        windows: [
          participants: [partition_by: resolved.requested_id],
          recent: [
            partition_by: resolved.requested_id,
            order_by: [desc: resolved.last_seen, asc: resolved.person_id]
          ]
        ],
        select: %{
          requested_id: resolved.requested_id,
          person_id: resolved.person_id,
          display_name: resolved.display_name,
          participant_count: over(count(), :participants),
          recent_rank: over(row_number(), :recent)
        }

    from(ranked in "ranked",
      where: ranked.recent_rank <= 3,
      order_by: [ranked.requested_id, ranked.recent_rank],
      select: %{
        requested_id: type(ranked.requested_id, Ecto.UUID),
        person_id: ranked.person_id,
        display_name: ranked.display_name,
        participant_count: ranked.participant_count
      }
    )
    |> with_cte("requested", as: ^requested)
    |> with_cte("resolved", as: ^resolved)
    |> with_cte("ranked", as: ^ranked)
    |> Repo.all()
    |> Enum.reduce(%{}, fn row, acc ->
      entry = Map.get(acc, row.requested_id, %{recent: [], count: row.participant_count})
      recent = entry.recent ++ [%{person_id: row.person_id, display_name: row.display_name}]
      Map.put(acc, row.requested_id, %{entry | recent: recent})
    end)
  end

  # Channel rows include their threads; thread rows include only their own messages
  # and the matching root message from the parent transcript.
  defp participant_message_scope do
    dynamic(
      [requested: requested, transcript: transcript, message: message],
      (is_nil(requested.parent_id) and
         (transcript.id == requested.id or transcript.parent_id == requested.id)) or
        (not is_nil(requested.parent_id) and
           (transcript.id == requested.id or
              (transcript.id == requested.parent_id and
                 message.external_message_id == requested.thread_id)))
    )
  end

  defp thread_counts(ids) do
    Repo.all(
      from transcript in Transcript,
        where: transcript.parent_id in ^ids,
        group_by: transcript.parent_id,
        select: {transcript.parent_id, count(transcript.id)}
    )
    |> Map.new()
  end

  defp first_messages(ids) do
    Repo.all(
      from placement in TranscriptMessage,
        join: message in Message,
        on: message.id == placement.message_id,
        where: placement.transcript_id in ^ids and message.role != "assistant",
        distinct: placement.transcript_id,
        order_by: [asc: placement.transcript_id, asc: placement.position],
        select: {placement.transcript_id, message}
    )
    |> Map.new()
  end

  defp stored_roots(rows) do
    parent_ids = rows |> Enum.map(& &1.parent_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    thread_ids = rows |> Enum.map(& &1.thread_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if parent_ids == [] or thread_ids == [] do
      %{}
    else
      candidates =
        Repo.all(
          from placement in TranscriptMessage,
            join: message in Message,
            on: message.id == placement.message_id,
            where:
              placement.transcript_id in ^parent_ids and
                message.external_message_id in ^thread_ids,
            select: {placement.transcript_id, message.external_message_id, message}
        )
        |> Map.new(fn {parent_id, external_id, message} ->
          {{parent_id, external_id}, message}
        end)

      Map.new(rows, fn row -> {row.id, Map.get(candidates, {row.parent_id, row.thread_id})} end)
    end
  end

  defp person_summaries(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Repo.all(
      from person in Person,
        where: person.id in ^ids or fragment("? && ?::bigint[]", person.merged_person_ids, ^ids)
    )
    |> Enum.flat_map(fn person ->
      summary = %{person_id: person.id, display_name: person.full_name || "Unnamed person"}
      Enum.map([person.id | person.merged_person_ids], &{&1, summary})
    end)
    |> Map.new()
  end

  defp root_identities(rows, roots) do
    descriptors =
      rows
      |> Enum.flat_map(fn row ->
        case Map.get(roots, row.id) do
          nil ->
            []

          message ->
            platform = message.history_context["identity_platform"] || row.provider
            [{row.channel_config_id, platform, message.author_id}]
        end
      end)
      |> Enum.reject(fn {config_id, platform, author_id} ->
        is_nil(config_id) or is_nil(platform) or is_nil(author_id)
      end)
      |> Enum.uniq()

    config_ids = Enum.map(descriptors, &elem(&1, 0))
    platforms = Enum.map(descriptors, &elem(&1, 1))
    author_ids = Enum.map(descriptors, &elem(&1, 2))

    Repo.all(
      from identity in PersonChannel,
        join: person in Person,
        on: person.id == identity.person_id,
        where:
          identity.channel_config_id in ^config_ids and identity.platform in ^platforms and
            identity.channel_identifier in ^author_ids,
        select:
          {{identity.channel_config_id, identity.platform, identity.channel_identifier},
           %{person_id: person.id, display_name: person.full_name}}
    )
    |> Map.new()
  end

  @doc "Returns positive and negative rating totals for a bounded message set."
  def rating_summaries([]), do: %{}

  def rating_summaries(ids) do
    Repo.all(
      from rating in MessageRating,
        where: rating.message_id in ^ids,
        group_by: rating.message_id,
        select:
          {rating.message_id,
           %{
             positive: filter(count(rating.id), rating.rating >= 4),
             negative: filter(count(rating.id), rating.rating < 4)
           }}
    )
    |> Map.new()
  end

  defp history_title(nil, fallback, _people), do: fallback

  defp history_title(message, fallback, people) do
    context = message.history_context || %{}

    case {context["title_style"], context["author_person_id"]} do
      {style, id} when style in ["person", "person_subject"] ->
        format_person_title(style, id, context, message, people)

      _ ->
        fallback
    end
  end

  defp format_person_title(style, id, context, message, people) do
    name =
      case Map.get(people, id) do
        %{display_name: name} when is_binary(name) and name != "" -> name
        _ -> message.author_name || message.author_id || "Person"
      end

    if style == "person_subject",
      do: "#{name}: #{context["subject"] || "(No subject)"}",
      else: name
  end

  defp display_root(nil, _row, _people, _identities, _ratings), do: nil

  defp display_root(message, row, people, identities, ratings) do
    context = message.history_context || %{}
    platform = context["identity_platform"] || row.provider

    resolved =
      case context["author_person_id"] do
        id when is_integer(id) -> Map.get(people, id)
        _ -> Map.get(identities, {row.channel_config_id, platform, message.author_id})
      end

    author =
      resolved ||
        %{display_name: message.author_name || message.author_id || "Person", person_id: nil}

    %{
      message_id: message.id,
      author_id: message.author_id,
      author_name: message.author_name,
      role: message.role,
      content: message.content,
      attachments: message.attachments,
      provider_sent_at: message.provider_sent_at,
      inserted_at: message.provider_sent_at || message.inserted_at,
      display_name: author.display_name,
      person_id: author.person_id,
      feedback: nil,
      rating_summary: Map.get(ratings, message.id, %{positive: 0, negative: 0})
    }
  end

  defp author_person_id(nil), do: nil
  defp author_person_id(message), do: (message.history_context || %{})["author_person_id"]
end

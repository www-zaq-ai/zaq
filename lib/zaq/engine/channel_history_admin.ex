defmodule Zaq.Engine.ChannelHistoryAdmin do
  @moduledoc """
  Bounded canonical channel-history inspection for an already authenticated BO
  super-admin. `Engine.Api` verifies the current user and confidential event;
  this module never accepts a caller-supplied Person grant as authorization.
  """

  import Ecto.Query

  alias Zaq.Accounts.{People, Person, PersonChannel}
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.RetrievalChannel
  alias Zaq.Engine.Conversations

  alias Zaq.Engine.Conversations.{
    Message,
    MessageRating,
    Transcript,
    TranscriptHistory,
    TranscriptMessage
  }

  alias Zaq.Engine.Workflows.Actions.RefreshChannelHistoryMembership
  alias Zaq.Permissions
  alias Zaq.Repo

  @max_transcripts 50

  @doc "Lists current connector transcripts and explicitly restricted legacy snapshots."
  def dispatch(%{op: :list} = request) do
    limit = Map.get(request, :limit, @max_transcripts)
    offset = Map.get(request, :offset, 0)
    parent_id = Map.get(request, :parent_id)

    scope =
      if is_nil(parent_id),
        do: dynamic([t], is_nil(t.parent_id)),
        else: dynamic([t], t.parent_id == ^parent_id)

    with true <- valid_list_request?(limit, offset, parent_id),
         {:ok, parent} <- list_parent_context(parent_id) do
      rows =
        Repo.all(
          from t in Transcript,
            left_join: config in ChannelConfig,
            on: config.id == t.channel_config_id and config.provider == t.provider,
            left_join: room in RetrievalChannel,
            on:
              room.channel_config_id == t.channel_config_id and
                room.channel_id == t.external_channel_id,
            where: t.strategy == "legacy" or not is_nil(config.id),
            where: ^scope,
            order_by: [desc: t.updated_at, desc: t.id],
            limit: ^(limit + 1),
            offset: ^offset,
            select: %{
              id: t.id,
              provider: t.provider,
              channel_config_id: t.channel_config_id,
              connector: fragment("COALESCE(?, 'Restricted legacy')", config.name),
              channel_id: t.external_channel_id,
              channel_name:
                fragment(
                  "COALESCE(NULLIF(?, ''), ?, 'Restricted legacy')",
                  room.channel_name,
                  config.name
                ),
              thread_id: t.external_thread_id,
              parent_id: t.parent_id,
              strategy: t.strategy,
              owner_person_id: t.owner_person_id,
              position: t.next_position,
              updated_at: t.updated_at
            }
        )

      owners = person_summaries(Enum.map(rows, & &1.owner_person_id))

      displayed =
        rows
        |> Enum.take(limit)
        |> Enum.map(fn row ->
          row
          |> Map.put(:owner, Map.get(owners, row.owner_person_id))
          |> summarize_row(request[:actor])
        end)

      if Map.has_key?(request, :offset),
        do: {:ok, %{rows: displayed, has_more: length(rows) > limit, parent: parent}},
        else: {:ok, displayed}
    else
      false -> {:error, :invalid_request}
      {:error, _} = error -> error
    end
  end

  def dispatch(%{op: :detail, id: id} = request) do
    cursor = Map.get(request, :cursor, 0)

    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Transcript{} = transcript <- Repo.get(Transcript, uuid),
         {:ok, config} <- admin_connector(transcript),
         {:ok, messages} <- TranscriptHistory.list_admin(uuid, after_position: cursor, limit: 50) do
      {:ok,
       %{
         transcript: %{
           id: transcript.id,
           channel_id: transcript.external_channel_id,
           channel_name: channel_name(transcript, config),
           thread_id: transcript.external_thread_id,
           parent_id: transcript.parent_id,
           provider: transcript.provider,
           connector: config.name,
           strategy: transcript.strategy,
           owner_person_id: transcript.owner_person_id,
           owner:
             Map.get(person_summaries([transcript.owner_person_id]), transcript.owner_person_id),
           position: transcript.next_position,
           refresh_supported?: refresh_supported?(transcript)
         },
         grants: grants_for(transcript),
         root_message: root_message(transcript, request[:actor]),
         messages: display_messages(messages, transcript, get_in(request, [:actor, :user_id]))
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  def dispatch(%{op: :grant, id: id, person_id: person_id})
      when is_integer(person_id) and person_id > 0 do
    with {:ok, resource} <- grant_resource(id),
         %Person{status: "active"} <- Repo.get(Person, person_id) do
      case Permissions.grant(resource, %{person_id: person_id, access_rights: ["read"]}) do
        {:ok, _} -> {:ok, :granted}
        {:error, _} -> {:error, :invalid_person}
      end
    else
      nil -> {:error, :invalid_person}
      {:error, _} = error -> error
      _ -> {:error, :invalid_person}
    end
  end

  def dispatch(%{op: :revoke, id: id, person_id: person_id})
      when is_integer(person_id) and person_id > 0 do
    with {:ok, resource} <- grant_resource(id) do
      revoke_manual(resource, person_id)
    end
  end

  def dispatch(%{op: :refresh, id: id, actor: actor}) do
    case Jido.Exec.run(RefreshChannelHistoryMembership, %{transcript_id: id}, %{actor: actor}) do
      {:ok, %{members: _} = result} -> {:ok, result}
      {:error, %{details: %{reason: reason}}} -> {:error, reason}
      {:error, _} -> {:error, :membership_refresh_failed}
    end
  end

  def dispatch(%{op: :message_info, id: id, message_id: message_id}) do
    with {:ok, message} <- transcript_message(id, message_id) do
      {:ok,
       Map.take(message, [
         :id,
         :model,
         :metadata,
         :trace,
         :prompt_tokens,
         :completion_tokens,
         :total_tokens,
         :latency_ms,
         :confidence_score
       ])}
    end
  end

  def dispatch(%{
        op: :rate,
        id: id,
        message_id: message_id,
        rating: rating,
        actor: %{user_id: user_id}
      })
      when rating in [1, 5] do
    case transcript_message(id, message_id) do
      {:ok, %Message{role: "assistant"} = message} ->
        Conversations.upsert_rating(message, %{user_id: user_id, rating: rating})

      _ ->
        {:error, :not_found}
    end
  end

  def dispatch(_), do: {:error, :invalid_request}

  defp list_parent_context(nil), do: {:ok, nil}

  defp list_parent_context(id) do
    with %Transcript{parent_id: nil} = parent <- Repo.get(Transcript, id),
         {:ok, config} <- admin_connector(parent),
         {:ok, _} <- TranscriptHistory.list_admin(id, limit: 1) do
      {:ok, %{id: parent.id, channel_name: channel_name(parent, config)}}
    else
      _ -> {:error, :not_found}
    end
  end

  defp valid_list_request?(limit, offset, parent_id) do
    is_integer(limit) and limit in 1..@max_transcripts and is_integer(offset) and
      offset in 0..10_000 and
      (is_nil(parent_id) or match?({:ok, _}, Ecto.UUID.cast(parent_id)))
  end

  defp summarize_row(row, actor) do
    transcript = Repo.get!(Transcript, row.id)
    {participants, count} = participants(transcript)

    Map.merge(row, %{
      channel_name: history_title(transcript, row.channel_name),
      participants: participants,
      participant_count: count,
      thread_count: Repo.aggregate(from(t in Transcript, where: t.parent_id == ^row.id), :count),
      root_message: root_message(transcript, actor)
    })
  end

  defp participants(transcript) do
    scope = participant_scope(transcript)

    query =
      from t in Transcript,
        join: placement in TranscriptMessage,
        on: placement.transcript_id == t.id,
        join: m in Message,
        on: m.id == placement.message_id,
        left_join: c in PersonChannel,
        on:
          c.channel_config_id == t.channel_config_id and
            is_nil(fragment("?->>'author_person_id'", m.history_context)) and
            c.platform ==
              fragment("COALESCE(?->>'identity_platform', ?)", m.history_context, t.provider) and
            c.channel_identifier == m.author_id,
        join: p in Person,
        on:
          p.id == c.person_id or
            fragment(
              "EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(?->'participants', '[]'::jsonb)) participant WHERE (participant->>'person_id')::bigint = ANY(array_prepend(?::bigint, ?::bigint[])))",
              m.history_context,
              p.id,
              p.merged_person_ids
            ),
        where: ^scope,
        where: m.role != "assistant"

    count = Repo.one(from [t, placement, m, c, p] in query, select: count(p.id, :distinct))

    recent =
      Repo.all(
        from [t, placement, m, c, p] in query,
          group_by: [p.id, p.full_name],
          order_by: [
            desc: max(fragment("COALESCE(?, ?)", m.provider_sent_at, m.inserted_at)),
            asc: p.id
          ],
          limit: 3,
          select: %{person_id: p.id, display_name: p.full_name}
      )

    {recent, count}
  end

  defp participant_scope(%{parent_id: nil} = transcript),
    do: dynamic([t], t.id == ^transcript.id or t.parent_id == ^transcript.id)

  defp participant_scope(transcript),
    do:
      dynamic(
        [t, _placement, m],
        t.id == ^transcript.id or
          (t.id == ^transcript.parent_id and
             m.external_message_id == ^transcript.external_thread_id)
      )

  defp refresh_supported?(%{strategy: "shared"} = transcript) do
    event =
      Zaq.Event.new(
        %{
          channel_config_id: transcript.channel_config_id,
          channel_id: transcript.external_channel_id
        },
        :channels,
        opts: [action: :channel_history_capabilities]
      )

    match?(
      %Zaq.Event{response: {:ok, %{membership_refresh: true}}},
      Zaq.NodeRouter.dispatch(event)
    )
  end

  defp refresh_supported?(_transcript), do: false

  defp root_message(%{parent_id: nil}, _actor), do: nil

  defp root_message(transcript, actor) do
    stored =
      Repo.one(
        from m in Message,
          join: p in TranscriptMessage,
          on: p.message_id == m.id,
          where:
            p.transcript_id == ^transcript.parent_id and
              m.external_message_id == ^transcript.external_thread_id,
          select: %{
            message_id: m.id,
            author_id: m.author_id,
            author_name: m.author_name,
            role: m.role,
            content: m.content,
            attachments: m.attachments,
            provider_sent_at: m.provider_sent_at
          }
      )

    case stored do
      nil -> fetch_root(transcript, actor)
      message -> hd(display_messages([message], transcript, nil))
    end
  end

  defp fetch_root(transcript, actor) do
    event =
      Zaq.Event.new(
        %{
          channel_config_id: transcript.channel_config_id,
          channel_id: transcript.external_channel_id,
          message_id: transcript.external_thread_id
        },
        :channels,
        actor: actor,
        opts: [action: :channel_history_root, confidential: true]
      )

    case Zaq.NodeRouter.dispatch(event).response do
      {:ok, message} ->
        identity = author_names([message], transcript)[message.author_id]

        Map.merge(message, %{
          message_id: nil,
          feedback: nil,
          person_id: identity && identity.person_id,
          display_name:
            (identity && identity.display_name) || message.author_name || "Unknown author"
        })

      _ ->
        nil
    end
  end

  defp transcript_message(id, message_id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, message_id} <- Ecto.UUID.cast(message_id),
         {:ok, _} <- TranscriptHistory.list_admin(id, limit: 1),
         %Message{} = message <-
           Repo.one(
             from m in Message,
               join: p in TranscriptMessage,
               on: p.message_id == m.id,
               where: p.transcript_id == ^id and m.id == ^message_id,
               select: m
           ) do
      {:ok, message}
    else
      _ -> {:error, :not_found}
    end
  end

  defp channel_name(transcript, config) do
    room =
      if transcript.channel_config_id && transcript.external_channel_id,
        do:
          Repo.get_by(RetrievalChannel,
            channel_config_id: transcript.channel_config_id,
            channel_id: transcript.external_channel_id
          )

    fallback =
      if room && room.channel_name not in [nil, ""], do: room.channel_name, else: config.name

    history_title(transcript, fallback)
  end

  defp history_title(transcript, fallback) do
    first =
      Repo.one(
        from m in Message,
          join: placement in TranscriptMessage,
          on: placement.message_id == m.id,
          where: placement.transcript_id == ^transcript.id and m.role != "assistant",
          order_by: [asc: placement.position],
          limit: 1,
          select: m
      )

    case first do
      %Message{history_context: %{"title_style" => style, "author_person_id" => id} = context}
      when style in ["person", "person_subject"] ->
        name = history_author_name(id, first)

        if style == "person_subject",
          do: "#{name}: #{context["subject"] || "(No subject)"}",
          else: name

      _ ->
        fallback
    end
  end

  defp history_author_name(id, message) do
    case People.get_person(id) do
      %Person{full_name: name} when is_binary(name) and name != "" -> name
      _ -> message.author_name || message.author_id || "Person"
    end
  end

  defp display_messages(messages, transcript, user_id) do
    ids = Enum.map(messages, & &1.message_id)
    stored = Repo.all(from m in Message, where: m.id in ^ids) |> Map.new(&{&1.id, &1})
    names = author_names(Map.values(stored), transcript)
    people = persisted_author_names(Map.values(stored))
    ratings = current_ratings(ids, user_id)
    summaries = rating_summaries(ids)

    Enum.map(messages, fn message ->
      record = Map.fetch!(stored, message.message_id)

      message
      |> Map.merge(display_author(record, names, people))
      |> Map.merge(%{
        feedback: Map.get(ratings, message.message_id),
        rating_summary: Map.get(summaries, message.message_id, %{positive: 0, negative: 0}),
        inserted_at: record.provider_sent_at || record.inserted_at
      })
    end)
  end

  defp persisted_author_names(messages) do
    messages |> Enum.map(& &1.history_context["author_person_id"]) |> person_summaries()
  end

  defp person_summaries(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Repo.all(
      from p in Person,
        where: p.id in ^ids or fragment("? && ?::bigint[]", p.merged_person_ids, ^ids)
    )
    |> Enum.flat_map(fn person ->
      Enum.map(
        [person.id | person.merged_person_ids],
        &{&1, %{person_id: person.id, display_name: person.full_name || "Unnamed person"}}
      )
    end)
    |> Map.new()
  end

  defp display_author(%{role: "assistant"} = record, _names, _people),
    do: %{display_name: agent_name(record.metadata || %{}), person_id: nil}

  defp display_author(record, names, people) do
    resolved =
      case record.history_context["author_person_id"] do
        id when is_integer(id) -> Map.get(people, id)
        _ -> Map.get(names, record.author_id)
      end

    resolved ||
      %{display_name: record.author_name || record.author_id || "Person", person_id: nil}
  end

  defp author_names(_messages, %{channel_config_id: nil}), do: %{}

  defp author_names(messages, transcript) do
    ids = Enum.map(messages, & &1.author_id) |> Enum.reject(&is_nil/1)

    platforms =
      Enum.map(messages, fn message ->
        context = Map.get(message, :history_context, %{})
        context["identity_platform"] || transcript.provider
      end)
      |> Enum.uniq()

    Repo.all(
      from c in PersonChannel,
        join: p in Person,
        on: p.id == c.person_id,
        where:
          c.channel_config_id == ^transcript.channel_config_id and
            c.platform in ^platforms and c.channel_identifier in ^ids,
        select: {c.channel_identifier, %{display_name: p.full_name, person_id: p.id}}
    )
    |> Map.new()
  end

  defp current_ratings(_ids, nil), do: %{}

  defp current_ratings(ids, user_id) do
    Repo.all(
      from r in MessageRating,
        where: r.message_id in ^ids and r.user_id == ^user_id,
        select: {r.message_id, r.rating}
    )
    |> Map.new(fn {id, rating} -> {id, if(rating >= 4, do: :positive, else: :negative)} end)
  end

  defp rating_summaries(ids) do
    Repo.all(
      from r in MessageRating,
        where: r.message_id in ^ids,
        group_by: r.message_id,
        select:
          {r.message_id,
           %{
             positive: filter(count(r.id), r.rating >= 4),
             negative: filter(count(r.id), r.rating < 4)
           }}
    )
    |> Map.new()
  end

  defp agent_name(metadata) do
    case metadata["agent"] do
      %{"name" => name} when is_binary(name) -> name
      name when is_binary(name) -> name
      _ -> "ZAQ"
    end
  end

  defp admin_connector(%Transcript{strategy: "legacy"}),
    do: {:ok, %{name: "Restricted legacy", enabled: false, archived_at: nil}}

  defp admin_connector(%Transcript{} = transcript) do
    case Repo.get(ChannelConfig, transcript.channel_config_id) do
      %ChannelConfig{provider: provider} = config when provider == transcript.provider ->
        {:ok, config}

      _ ->
        {:error, :not_found}
    end
  end

  defp grants_for(transcript) do
    {transcript.permission_resource_type, transcript.permission_resource_id}
    |> Permissions.list_direct()
    |> Enum.map(fn grant ->
      %{
        person_id: grant.person_id,
        team_id: grant.team_id,
        source: grant.source_key,
        access_rights: grant.access_rights
      }
    end)
  end

  defp revoke_manual(resource, person_id) do
    grant =
      resource
      |> Permissions.list_direct()
      |> Enum.find(&(&1.person_id == person_id and &1.source_key == "manual"))

    case grant do
      nil ->
        {:ok, :revoked}

      grant ->
        case Permissions.revoke(resource, grant) do
          :ok -> {:ok, :revoked}
          {:error, _} -> {:error, :grant_revocation_failed}
        end
    end
  end

  defp grant_resource(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Transcript{strategy: strategy} = transcript <- Repo.get(Transcript, uuid),
         true <- strategy in ["shared", "direct"],
         {:ok, _} <- TranscriptHistory.list_admin(uuid, limit: 1) do
      {:ok, {transcript.permission_resource_type, transcript.permission_resource_id}}
    else
      _ -> {:error, :not_found}
    end
  end
end

defmodule Zaq.Engine.Conversations do
  @moduledoc """
  Context module for managing conversations, messages, ratings, and shares.

  All functions in this module operate on `Zaq.Repo` directly. BO LiveViews
  must call these functions via `Zaq.NodeRouter.dispatch/1` with `%Zaq.Event{}`.
  """

  import Ecto.Query

  alias Zaq.Engine.Conversations.{
    Conversation,
    ConversationShare,
    Message,
    MessageRating,
    TitleGenerator,
    TokenUsageAggregator
  }

  alias Zaq.Accounts.{Person, PersonChannel}
  alias Zaq.Agent.CitationNormalizer
  alias Zaq.Agent.StreamEvents
  alias Zaq.Engine.Messages.{Incoming, Measurements, Outgoing}
  alias Zaq.Engine.Telemetry
  alias Zaq.Repo

  # ── Conversations ──────────────────────────────────────────────────

  @doc "Creates a new conversation."
  def create_conversation(attrs) do
    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Fetches a conversation by id, returns nil if not found."
  def get_conversation(id), do: Repo.get(Conversation, id)

  @doc "Fetches a conversation by id, raises if not found."
  def get_conversation!(id) do
    Repo.get!(Conversation, id)
  end

  @doc """
  Returns an existing active conversation for the given channel user and type,
  or creates a new one. Optionally scoped by channel_config_id.
  """
  def get_or_create_conversation_for_channel(channel_user_id, channel_type, channel_config_id) do
    if is_nil(channel_user_id) do
      create_conversation(%{
        channel_user_id: channel_user_id,
        channel_type: channel_type,
        channel_config_id: channel_config_id
      })
    else
      query =
        from c in Conversation,
          where:
            c.channel_user_id == ^channel_user_id and
              c.channel_type == ^channel_type and
              c.status == "active",
          order_by: [desc: c.inserted_at],
          limit: 1

      query =
        if channel_config_id do
          where(query, [c], c.channel_config_id == ^channel_config_id)
        else
          query
        end

      case Repo.one(query) do
        %Conversation{} = conv ->
          {:ok, conv}

        nil ->
          create_conversation(%{
            channel_user_id: channel_user_id,
            channel_type: channel_type,
            channel_config_id: channel_config_id
          })
      end
    end
  end

  @doc """
  Lists conversations with optional filters.

  Supported opts:

  - `user_id`, `channel_user_id`, `channel_type`, `status`, `person_id`,
    `team_id`, `limit`, `offset` — equality/scoping filters.
  - `query` — case-insensitive text search. SQL wildcards in the input are
    matched literally; blank input applies no filter.
  - `search_in` — scopes `query` to `:title`, `:content`, or `:all` (default).
    Ignored when `query` is absent.
  - `from` / `to` — `DateTime` bounds (inclusive) on `updated_at`.
  """
  def list_conversations(opts \\ []) do
    search_in = Keyword.get(opts, :search_in, :all)
    query = from(c in Conversation, order_by: [desc: c.updated_at])

    query =
      Enum.reduce(opts, query, fn
        {:user_id, user_id}, q ->
          where(q, [c], c.user_id == ^user_id)

        {:channel_user_id, id}, q ->
          where(q, [c], c.channel_user_id == ^id)

        {:channel_type, channel_type}, q ->
          where(q, [c], c.channel_type == ^channel_type)

        {:status, status}, q ->
          where(q, [c], c.status == ^status)

        {:person_id, person_id}, q ->
          where(q, [c], c.person_id == ^person_id)

        {:team_id, team_id}, q ->
          person_subquery = from(p in Person, where: ^team_id in p.team_ids, select: p.id)
          where(q, [c], c.person_id in subquery(person_subquery))

        {:query, text}, q when is_binary(text) ->
          apply_search_filter(q, String.trim(text), search_in)

        {:from, %DateTime{} = from}, q ->
          where(q, [c], c.updated_at >= ^from)

        {:to, %DateTime{} = to}, q ->
          where(q, [c], c.updated_at <= ^to)

        {:limit, n}, q ->
          limit(q, ^n)

        {:offset, n}, q ->
          offset(q, ^n)

        _, q ->
          q
      end)

    query
    |> Repo.all()
    |> backfill_missing_person_ids()
    |> Repo.preload([:person, :user])
  end

  defp apply_search_filter(query, "", _scope), do: query

  defp apply_search_filter(query, text, scope) do
    pattern = "%" <> escape_like_wildcards(text) <> "%"
    apply_scoped_search(query, pattern, scope)
  end

  defp apply_scoped_search(query, pattern, :title),
    do: where(query, [c], ilike(c.title, ^pattern))

  defp apply_scoped_search(query, pattern, :content),
    do: where(query, [c], c.id in subquery(content_matches(pattern)))

  defp apply_scoped_search(query, pattern, _all),
    do: where(query, [c], ilike(c.title, ^pattern) or c.id in subquery(content_matches(pattern)))

  defp content_matches(pattern),
    do: from(m in Message, where: ilike(m.content, ^pattern), select: m.conversation_id)

  # ILIKE parameters are injection-safe, but `%`/`_` in user input would act
  # as wildcards — escape them so search terms match literally.
  defp escape_like_wildcards(text) do
    String.replace(text, ~r/([\\%_])/, "\\\\\\1")
  end

  @doc "Updates a conversation with the given attrs."
  def update_conversation(%Conversation{} = conversation, attrs) do
    conversation
    |> Conversation.changeset(attrs)
    |> Repo.update()
  end

  @doc "Sets the conversation status to archived."
  def archive_conversation(%Conversation{} = conversation) do
    update_conversation(conversation, %{status: "archived"})
  end

  @doc "Archives a conversation by ID."
  def archive_conversation_by_id(id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.update_all(from(c in Conversation, where: c.id == ^id),
      set: [status: "archived", updated_at: now]
    )

    :ok
  end

  @doc "Deletes a conversation by ID."
  def delete_conversation_by_id(id) do
    Repo.delete_all(from(c in Conversation, where: c.id == ^id))
    :ok
  end

  @doc "Deletes a conversation and all associated messages (cascaded by DB)."
  def delete_conversation(%Conversation{} = conversation) do
    Repo.delete(conversation)
  end

  @doc """
  Persists a user message and its pipeline result into a conversation.
  Gets or creates a conversation scoped to the sender and provider (channel type).
  """
  def persist_from_incoming(%Zaq.Engine.Messages.Incoming{} = msg, result) do
    {channel_type, conversation_key} = conversation_identity(msg)
    channel_user_id = conversation_key || msg.author_id
    %{body: assistant_body, sources: assistant_sources} = normalize_assistant_response(result)

    with {:ok, conv} <- conversation_for_persistence(msg, channel_user_id, channel_type),
         {:ok, conv} <- maybe_store_author_id(conv, msg.author_id),
         {:ok, conv} <-
           maybe_assign_person(conv, Incoming.person_id(msg) || Map.get(result, :person_id)),
         {:ok, _} <- add_message(conv, %{role: "user", content: msg.content}),
         {:ok, assistant_msg} <-
           add_message(conv, %{
             role: "assistant",
             content: assistant_body,
             confidence_score: result.confidence_score,
             latency_ms: result.latency_ms,
             prompt_tokens: result.prompt_tokens,
             completion_tokens: result.completion_tokens,
             total_tokens: result.total_tokens,
             model: Map.get(result, :model) || Map.get(result, "model"),
             sources: assistant_sources,
             metadata: assistant_metadata(result),
             trace: assistant_trace(result)
           }) do
      {:ok, %{conversation_id: conv.id, assistant_message_id: assistant_msg.id}}
    end
  end

  @doc """
  Persists one message into the conversation resolved from an incoming routing envelope.

  Unlike `persist_from_incoming/2`, this stores exactly one message and defaults
  the message role to `"assistant"`, which supports assistant-initiated follow-ups
  or notifications without fabricating a user turn.
  """
  def persist_message_history(%Incoming{} = msg, attrs) when is_map(attrs) do
    {channel_type, conversation_key} = conversation_identity(msg)
    channel_user_id = conversation_key || msg.author_id || msg.channel_id

    message_attrs = message_history_attrs(attrs, msg)

    with {:ok, conv} <- conversation_for_persistence(msg, channel_user_id, channel_type),
         {:ok, conv} <- maybe_store_author_id(conv, msg.author_id),
         {:ok, conv} <-
           maybe_assign_person(conv, Incoming.person_id(msg) || map_get(attrs, "person_id")),
         {:ok, conv} <- maybe_assign_history_title(conv, message_history_title(attrs, msg)),
         {:ok, message} <- add_message(conv, message_attrs) do
      {:ok, %{conversation_id: conv.id, message_id: message.id}}
    end
  end

  # The delivering channel computes conversation identity and stamps it on the
  # incoming envelope (`metadata["conversation"]`) before it reaches the engine
  # — see `Zaq.Channels.CommunicationBridge.put_conversation_identity/2`.
  # Messages that never pass through a channel node (BO chat, direct API) carry
  # no stamp and group generically: the provider names the channel type and the
  # caller-supplied author is the grouping key.
  defp conversation_identity(%Incoming{} = msg) do
    case msg.metadata do
      %{"conversation" => %{"channel_type" => channel_type} = identity}
      when is_binary(channel_type) and channel_type != "" ->
        {channel_type, identity_key(identity)}

      _ ->
        {default_channel_type(msg.provider), nil}
    end
  end

  defp identity_key(identity) do
    case Map.get(identity, "key") do
      key when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  defp default_channel_type(nil), do: "api"

  defp default_channel_type(provider) when is_atom(provider),
    do: default_channel_type(Atom.to_string(provider))

  defp default_channel_type("web"), do: "bo"
  defp default_channel_type(provider) when is_binary(provider), do: provider
  defp default_channel_type(_provider), do: "api"

  defp conversation_for_persistence(msg, channel_user_id, channel_type) do
    case metadata_conversation_id(msg.metadata) do
      id when is_binary(id) and id != "" ->
        case get_conversation(id) do
          %Conversation{} = conv -> {:ok, conv}
          nil -> {:error, :conversation_not_found}
        end

      _ ->
        get_or_create_conversation_for_channel(channel_user_id, channel_type, nil)
    end
  end

  defp metadata_conversation_id(metadata) when is_map(metadata),
    do: Map.get(metadata, :conversation_id) || Map.get(metadata, "conversation_id")

  defp metadata_conversation_id(_), do: nil

  defp normalize_assistant_response(result) when is_map(result) do
    body = Map.get(result, :answer) || Map.get(result, "answer") || ""
    sources = Map.get(result, :sources) || Map.get(result, "sources") || []
    CitationNormalizer.normalize(body, sources)
  end

  defp assistant_metadata(result) when is_map(result) do
    %{
      "external_message_id" =>
        Map.get(result, :status_message_id) || Map.get(result, :message_id) ||
          Map.get(result, "status_message_id") || Map.get(result, "message_id"),
      "measurements" =>
        result
        |> Map.get(:measurements, Map.get(result, "measurements", %{}))
        |> Measurements.metadata_measurements(),
      "model" => Map.get(result, :model) || Map.get(result, "model"),
      "agent" => Map.get(result, :agent) || Map.get(result, "agent")
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, %{}] end)
    |> Map.new()
    |> StreamEvents.json_safe()
  end

  defp assistant_trace(result) when is_map(result) do
    result
    |> Map.get(:trace, Map.get(result, "trace", []))
    |> StreamEvents.json_safe()
  end

  defp message_history_attrs(attrs, %Incoming{} = incoming) do
    %{
      role: map_get(attrs, "role") || "assistant",
      content: map_get(attrs, "content") || incoming.content,
      confidence_score: map_get(attrs, "confidence_score"),
      latency_ms: map_get(attrs, "latency_ms"),
      prompt_tokens: map_get(attrs, "prompt_tokens"),
      completion_tokens: map_get(attrs, "completion_tokens"),
      total_tokens: map_get(attrs, "total_tokens"),
      model: map_get(attrs, "model"),
      sources: (map_get(attrs, "sources") || []) |> StreamEvents.json_safe(),
      metadata: (map_get(attrs, "metadata") || %{}) |> StreamEvents.json_safe(),
      trace: (map_get(attrs, "trace") || []) |> StreamEvents.json_safe()
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp message_history_title(attrs, %Incoming{} = incoming) do
    message_metadata = map_get(attrs, "metadata")

    first_present([
      map_get(message_metadata, "topic"),
      map_get(message_metadata, "subject"),
      map_get(incoming.metadata, "topic"),
      map_get(incoming.metadata, "subject")
    ])
  end

  defp maybe_assign_history_title(%Conversation{title: nil} = conv, title)
       when is_binary(title) do
    case String.trim(title) do
      "" ->
        {:ok, conv}

      title ->
        conv
        |> Conversation.changeset(%{title: title})
        |> Repo.update()
    end
  end

  defp maybe_assign_history_title(conv, _title), do: {:ok, conv}

  defp touch_conversation(%Conversation{} = conv) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    Repo.update_all(from(c in Conversation, where: c.id == ^conv.id), set: [updated_at: now])
  end

  defp maybe_assign_person(%Conversation{person_id: nil} = conv, person_id)
       when not is_nil(person_id) do
    conv
    |> Conversation.changeset(%{person_id: person_id})
    |> Repo.update()
  end

  defp maybe_assign_person(conv, _person_id), do: {:ok, conv}

  # When a channel groups conversations by something other than the sender
  # (e.g. a thread key), the sender is not recoverable from channel_user_id —
  # store author_id in metadata so person lookup still works.
  defp maybe_store_author_id(%Conversation{} = conv, author_id)
       when not is_nil(author_id) do
    if conv.channel_user_id == author_id or Map.get(conv.metadata, "author_id") do
      {:ok, conv}
    else
      conv
      |> Conversation.changeset(%{metadata: Map.put(conv.metadata, "author_id", author_id)})
      |> Repo.update()
    end
  end

  defp maybe_store_author_id(conv, _author_id), do: {:ok, conv}

  # Lazy backfill: for conversations with person_id nil, resolve via PersonChannel.
  # Two lookup strategies:
  #   1. channel_user_id → PersonChannel.channel_identifier (channels keyed by sender)
  #   2. metadata["author_id"] → PersonChannel.channel_identifier (channels keyed
  #      by a grouping key, where the sender lives in metadata)
  defp backfill_missing_person_ids(conversations) do
    unresolved = Enum.filter(conversations, &is_nil(&1.person_id))
    if unresolved == [], do: conversations, else: do_backfill(conversations, unresolved)
  end

  defp do_backfill(conversations, unresolved) do
    by_channel_user_id =
      unresolved |> Enum.map(& &1.channel_user_id) |> Enum.reject(&is_nil/1)

    by_author_id =
      unresolved |> Enum.map(&Map.get(&1.metadata, "author_id")) |> Enum.reject(&is_nil/1)

    lookup_ids = Enum.uniq(by_channel_user_id ++ by_author_id)

    channel_map =
      if lookup_ids == [] do
        %{}
      else
        Repo.all(
          from c in PersonChannel,
            where: c.channel_identifier in ^lookup_ids,
            select: {c.channel_identifier, c.person_id}
        )
        |> Map.new()
      end

    # Build a map of id → resolved person_id for conversations that need updating
    updates =
      Map.new(
        for conv <- conversations,
            is_nil(conv.person_id),
            resolved =
              Map.get(channel_map, conv.channel_user_id) ||
                Map.get(channel_map, Map.get(conv.metadata, "author_id")),
            not is_nil(resolved),
            do: {conv.id, resolved}
      )

    # Batch all DB writes in a single transaction instead of one query per row
    if map_size(updates) > 0, do: batch_update_person_ids(updates)

    Enum.map(conversations, fn conv ->
      case Map.get(updates, conv.id) do
        nil -> conv
        person_id -> %{conv | person_id: person_id}
      end
    end)
  end

  defp batch_update_person_ids(updates) do
    Repo.transaction(fn ->
      Enum.each(updates, fn {id, person_id} ->
        Repo.update_all(from(c in Conversation, where: c.id == ^id), set: [person_id: person_id])
      end)
    end)
  end

  @doc """
  Resolves the stored threading anchor for the next outbound send to
  `person_id`, in the conversation grouped under `conversation_key` on
  `channel_type`.

  The anchor is an opaque string-keyed map written at persist time by the
  delivering channel (`metadata["threading"]["anchor"]`) — it is returned
  verbatim and interpreted only by the provider bridge. The channel that wrote
  it also guarantees it is usable, so presence is the only filter here.
  Callers obtain `channel_type` and `conversation_key` from the channel node
  (the `:conversation_identity` event), so the lookup key always matches the
  key persistence grouped under.

  Returns `nil` when there is no conversation, when the key is blank, or when
  no message in it carries an anchor — the next send then starts a fresh chain.
  """
  def latest_thread_anchor(person_id, channel_type, conversation_key, opts \\ [])

  def latest_thread_anchor(nil, _channel_type, _conversation_key, _opts), do: nil

  def latest_thread_anchor(person_id, channel_type, conversation_key, _opts)
      when is_binary(channel_type) and is_binary(conversation_key) do
    if String.trim(conversation_key) == "" do
      nil
    else
      from(m in Message,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where:
          c.person_id == ^person_id and
            c.channel_type == ^channel_type and
            c.channel_user_id == ^conversation_key,
        where: fragment("? -> 'threading' -> 'anchor' IS NOT NULL", m.metadata),
        # Latest wins; `id` breaks sub-second `inserted_at` ties deterministically.
        order_by: [desc: m.inserted_at, desc: m.id],
        limit: 1,
        select: fragment("? -> 'threading' -> 'anchor'", m.metadata)
      )
      |> Repo.one()
    end
  end

  def latest_thread_anchor(_person_id, _channel_type, _conversation_key, _opts), do: nil

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, atom_key_for_string(map, key))
  end

  defp map_get(_map, _key), do: nil

  defp first_present(values) when is_list(values) do
    Enum.find(values, fn
      value when is_binary(value) -> String.trim(value) != ""
      value -> not is_nil(value)
    end)
  end

  defp atom_key_for_string(map, key) do
    Enum.find_value(map, fn
      {lookup_key, _value} when is_atom(lookup_key) ->
        if Atom.to_string(lookup_key) == key, do: lookup_key

      _ ->
        nil
    end)
  end

  # ── Messages ───────────────────────────────────────────────────────

  @doc """
  Adds a message to a conversation. If the message role is "assistant",
  enqueues a `TokenUsageAggregator` job.
  """
  def add_message(%Conversation{} = conversation, attrs) do
    attrs_with_id = Map.put(attrs, :conversation_id, conversation.id)

    result =
      %Message{}
      |> Message.changeset(attrs_with_id)
      |> Repo.insert()

    with {:ok, msg} <- result do
      touch_conversation(conversation)
      maybe_record_message_telemetry(conversation, msg)

      if msg.role == "assistant" do
        enqueue_token_aggregator(conversation.id, msg)
      end

      if msg.role == "user" && is_nil(conversation.title) do
        maybe_generate_title(conversation, msg.content)
      end

      {:ok, msg}
    end
  end

  @doc """
  Returns messages for a conversation in insertion order.

  Options:
  - `:limit` — cap the number of rows at the database level (`LIMIT`). With the
    ascending `inserted_at` order this returns the oldest `n` messages — pushing
    the truncation into SQL instead of fetching every row and trimming in memory.
  """
  def list_messages(%Conversation{} = conversation, opts \\ []) do
    from(m in Message,
      where: m.conversation_id == ^conversation.id,
      order_by: [asc: m.inserted_at],
      preload: [:ratings]
    )
    |> maybe_limit(opts[:limit])
    |> Repo.all()
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, n) when is_integer(n), do: limit(query, ^n)

  def store_external_message_id_by_outgoing(%Outgoing{} = outgoing, post_id)
      when is_binary(post_id) do
    thread_id = outgoing.thread_id
    channel_id = outgoing.channel_id

    if thread_id && channel_id do
      message =
        Repo.one(
          from m in Message,
            join: c in assoc(m, :conversation),
            where:
              c.channel_id == ^channel_id and
                fragment("?->>'thread_id' = ?", c.metadata, ^thread_id) and
                m.role == "assistant",
            order_by: [desc: m.inserted_at],
            limit: 1
        )

      if message, do: update_message_metadata(message.id, %{external_message_id: post_id})
    end
  end

  def get_message_by_external_id(external_id) do
    Repo.one(
      from m in Message, where: fragment("metadata->>'external_message_id' = ?", ^external_id)
    )
  end

  def update_message_metadata(message_id, attrs) when is_map(attrs) do
    Repo.get(Message, message_id)
    |> case do
      nil ->
        {:error, :not_found}

      msg ->
        new_metadata = Map.merge(msg.metadata || %{}, attrs)
        msg |> Message.changeset(%{metadata: new_metadata}) |> Repo.update()
    end
  end

  # ── Ratings ────────────────────────────────────────────────────────

  @doc "Creates a rating for a message."
  def rate_message(%Message{} = message, rater_attrs) do
    attrs = Map.put(rater_attrs, :message_id, message.id)

    %MessageRating{}
    |> MessageRating.changeset(attrs)
    |> Repo.insert()
    |> tap(fn
      {:ok, rating} -> maybe_record_rating_telemetry(rating, rater_attrs, message.inserted_at)
      _ -> :ok
    end)
  end

  @doc "Returns the rating for a message by a given user or channel_user."
  def get_rating(%Message{} = message, rater_attrs) do
    query = from(r in MessageRating, where: r.message_id == ^message.id)

    query =
      cond do
        user_id = Map.get(rater_attrs, :user_id) ->
          where(query, [r], r.user_id == ^user_id)

        channel_user_id = Map.get(rater_attrs, :channel_user_id) ->
          where(query, [r], r.channel_user_id == ^channel_user_id)

        true ->
          query
      end

    Repo.one(query)
  end

  @doc "Updates an existing rating."
  def update_rating(%MessageRating{} = rating, attrs, telemetry_attrs \\ %{}, occurred_at \\ nil) do
    rating
    |> MessageRating.changeset(attrs)
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> maybe_record_rating_telemetry(updated, telemetry_attrs, occurred_at)
      _ -> :ok
    end)
  end

  @doc "Deletes a rating."
  def delete_rating(%MessageRating{} = rating) do
    Repo.delete(rating)
  end

  @doc """
  Creates or updates a rating for a message identified by its UUID.
  Uses upsert semantics: if the rater already has a rating, it is updated.
  """
  def rate_message_by_id(message_id, rater_attrs) do
    case Repo.get(Message, message_id) do
      nil ->
        {:error, :not_found}

      message ->
        case get_rating(message, rater_attrs) do
          nil ->
            rate_message(message, rater_attrs)

          existing ->
            update_rating(
              existing,
              Map.take(rater_attrs, [:rating, :comment]),
              rater_attrs,
              message.inserted_at
            )
        end
        |> tap(fn
          {:ok, rating} ->
            conversation_history = list_conversation_messages(message.conversation_id)

            Zaq.Hooks.dispatch_async(
              :feedback_provided,
              %{
                message: message,
                rating: rating,
                conversation_history: conversation_history,
                rater_attrs: rater_attrs
              },
              %{}
            )

          _ ->
            :ok
        end)
    end
  end

  # ── Sharing ────────────────────────────────────────────────────────

  @doc "Creates a share for a conversation."
  def share_conversation(%Conversation{} = conversation, attrs) do
    attrs_with_id = Map.put(attrs, :conversation_id, conversation.id)

    %ConversationShare{}
    |> ConversationShare.changeset(attrs_with_id)
    |> Repo.insert()
  end

  @doc "Lists all shares for a conversation."
  def list_shares(%Conversation{} = conversation) do
    from(s in ConversationShare, where: s.conversation_id == ^conversation.id)
    |> Repo.all()
  end

  @doc "Deletes a share."
  def revoke_share(%ConversationShare{} = share) do
    Repo.delete(share)
  end

  @doc "Returns the conversation associated with a share token, or nil."
  def get_conversation_by_token(share_token) do
    case Repo.get_by(ConversationShare, share_token: share_token) do
      nil -> nil
      share -> Repo.get(Conversation, share.conversation_id)
    end
  end

  # ── Private ────────────────────────────────────────────────────────

  defp list_conversation_messages(conversation_id) do
    from(m in Message,
      where: m.conversation_id == ^conversation_id,
      order_by: [asc: m.inserted_at]
    )
    |> Repo.all()
  end

  defp enqueue_token_aggregator(conversation_id, %Message{model: model})
       when is_binary(model) do
    %{conversation_id: conversation_id, model: model}
    |> TokenUsageAggregator.new()
    |> Oban.insert()
  end

  defp enqueue_token_aggregator(_conversation_id, _msg), do: :ok

  defp maybe_record_message_telemetry(conversation, %Message{} = msg) do
    base = %{
      channel_type: conversation.channel_type,
      channel_config_id: to_string(conversation.channel_config_id || "unknown"),
      role: msg.role
    }

    case msg.role do
      "user" ->
        :ok

      "assistant" ->
        Telemetry.record("qa.answer.count", 1, base)

      _ ->
        :ok
    end

    :ok
  end

  defp maybe_record_rating_telemetry(%MessageRating{} = rating, attrs, occurred_at) do
    feedback_reasons =
      attrs
      |> Map.get(:feedback_reasons, [])
      |> List.wrap()

    Telemetry.record_feedback(
      rating.rating,
      %{
        channel_user_id: rating.channel_user_id || "bo_user",
        user_id: to_string(rating.user_id || "anonymous"),
        feedback_reasons: feedback_reasons
      },
      occurred_at: occurred_at
    )
  end

  # Fires async so it never blocks the message-storage path.
  # Only triggers on the very first user message (conversation.title is nil).
  defp maybe_generate_title(%Conversation{id: id} = _conversation, content) do
    if Application.get_env(:zaq, :title_generation_enabled, true) do
      Task.start(fn -> generate_and_apply_title(id, content) end)
    end
  end

  defp generate_and_apply_title(id, content) do
    case TitleGenerator.generate(content) do
      {:ok, title} -> apply_generated_title(id, title)
      {:fallback, title, _reason} -> apply_generated_title(id, title)
    end
  end

  defp apply_generated_title(id, title) do
    case Repo.get(Conversation, id) do
      %Conversation{} = conv ->
        update_conversation(conv, %{title: title})

        Phoenix.PubSub.broadcast(
          Zaq.PubSub,
          "conversation:#{id}",
          {:title_updated, id, title}
        )

      nil ->
        :ok
    end
  end
end

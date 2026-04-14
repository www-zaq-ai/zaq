defmodule Zaq.Engine.Conversations do
  @moduledoc """
  Context module for managing conversations, messages, ratings, and shares.

  All functions in this module operate on `Zaq.Repo` directly. BO LiveViews
  must call these functions via `Zaq.NodeRouter.call(:engine, Zaq.Engine.Conversations, ...)`.
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
  alias Zaq.Engine.Telemetry
  alias Zaq.Repo
  alias Zaq.Utils.EmailUtils

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

  Supported opts: `user_id`, `channel_user_id`, `status`, `limit`, `offset`.
  """
  def list_conversations(opts \\ []) do
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
    channel_type = normalize_channel_type(msg.provider)
    channel_user_id = conversation_channel_user_id(msg, channel_type)

    with {:ok, conv} <-
           get_or_create_conversation_for_channel(
             channel_user_id,
             channel_type,
             nil
           ),
         {:ok, conv} <- maybe_store_author_id(conv, msg.author_id),
         {:ok, conv} <- maybe_assign_person(conv, msg.person_id || Map.get(result, :person_id)),
         {:ok, _} <- add_message(conv, %{role: "user", content: msg.content}),
         {:ok, _} <-
           add_message(conv, %{
             role: "assistant",
             content: result.answer,
             confidence_score: result.confidence_score,
             latency_ms: result.latency_ms,
             prompt_tokens: result.prompt_tokens,
             completion_tokens: result.completion_tokens,
             total_tokens: result.total_tokens
           }) do
      :ok
    end
  end

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

  # Stores the sender's email address in conversation metadata for email:imap
  # conversations. The channel_user_id for email is a thread key (message ID),
  # not the sender address — storing author_id enables person lookup later.
  defp maybe_store_author_id(%Conversation{channel_type: "email:imap"} = conv, author_id)
       when not is_nil(author_id) do
    if Map.get(conv.metadata, "author_id") do
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
  #   1. channel_user_id → PersonChannel.channel_identifier (mattermost, slack, etc.)
  #   2. metadata["author_id"] → PersonChannel.channel_identifier (email:imap)
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

  defp normalize_channel_type(provider) when is_atom(provider),
    do: normalize_channel_type(to_string(provider))

  defp normalize_channel_type(provider) when is_binary(provider) do
    case provider do
      "email" -> "email:imap"
      other -> other
    end
  end

  defp normalize_channel_type(_), do: "api"

  defp conversation_channel_user_id(msg, "email:imap") do
    email_meta =
      msg.metadata
      |> map_get("email")
      |> case do
        meta when is_map(meta) -> meta
        _ -> %{}
      end

    # thread_key groups the whole email conversation by root reference.
    # thread_id remains useful for reply continuity, but grouping should stay stable.
    map_get(email_meta, "thread_key") ||
      EmailUtils.normalize_message_id(msg.thread_id) ||
      EmailUtils.normalize_message_id(msg.message_id) ||
      msg.author_id
  end

  defp conversation_channel_user_id(msg, _channel_type), do: msg.author_id

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, atom_key_for_string(map, key))
  end

  defp map_get(_map, _key), do: nil

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

  @doc "Returns all messages for a conversation in insertion order."
  def list_messages(%Conversation{} = conversation) do
    from(m in Message,
      where: m.conversation_id == ^conversation.id,
      order_by: [asc: m.inserted_at],
      preload: [:ratings]
    )
    |> Repo.all()
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
  def update_rating(%MessageRating{} = rating, attrs) do
    update_rating(rating, attrs, %{}, nil)
  end

  @doc "Updates an existing rating with telemetry context."
  def update_rating(%MessageRating{} = rating, attrs, telemetry_attrs) do
    update_rating(rating, attrs, telemetry_attrs, nil)
  end

  def update_rating(%MessageRating{} = rating, attrs, telemetry_attrs, occurred_at) do
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
        Telemetry.record("qa.message.count", 1, base)

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
      {:error, _reason} -> :ok
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

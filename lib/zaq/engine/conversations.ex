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

  Supported opts: `user_id`, `channel_user_id`, `status`, `limit`.
  """
  def list_conversations(opts \\ []) do
    query = from(c in Conversation, order_by: [desc: c.inserted_at])

    query =
      Enum.reduce(opts, query, fn
        {:user_id, user_id}, q -> where(q, [c], c.user_id == ^user_id)
        {:channel_user_id, id}, q -> where(q, [c], c.channel_user_id == ^id)
        {:channel_type, channel_type}, q -> where(q, [c], c.channel_type == ^channel_type)
        {:status, status}, q -> where(q, [c], c.status == ^status)
        {:limit, n}, q -> limit(q, ^n)
        _, q -> q
      end)

    Repo.all(query)
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

  @doc "Deletes a conversation and all associated messages (cascaded by DB)."
  def delete_conversation(%Conversation{} = conversation) do
    Repo.delete(conversation)
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
    rating
    |> MessageRating.changeset(attrs)
    |> Repo.update()
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
          nil -> rate_message(message, rater_attrs)
          existing -> update_rating(existing, Map.take(rater_attrs, [:rating, :comment]))
        end
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

  defp enqueue_token_aggregator(conversation_id, %Message{model: model})
       when is_binary(model) do
    %{conversation_id: conversation_id, model: model}
    |> TokenUsageAggregator.new()
    |> Oban.insert()
  end

  defp enqueue_token_aggregator(_conversation_id, _msg), do: :ok

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

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
    ExecutionRecord,
    Message,
    MessageRating,
    MessageTraceArtifact,
    TitleGenerator,
    TokenUsageAggregator,
    Transcript,
    TranscriptHistory,
    TranscriptMessage
  }

  alias Zaq.Accounts.{People, Person, PersonChannel, User}
  alias Zaq.Agent.CitationNormalizer
  alias Zaq.Agent.StreamEvents
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.History.{CommunicationPolicy, Facts}
  alias Zaq.Engine.Messages.{ConversationIdentity, Incoming, Measurements, SourceIdentity}
  alias Zaq.Engine.Messages.Incoming.Audience
  alias Zaq.Engine.Telemetry
  alias Zaq.Repo

  @doc "Appends canonical content to a transcript from an internally trusted channel source."
  @spec append_canonical_message(term(), map(), map()) ::
          {:ok, map()} | {:error, term()}
  def append_canonical_message(transcript_id, message_attrs, source_context),
    do: TranscriptHistory.append(transcript_id, message_attrs, source_context)

  @doc "Atomically places one provider message into its strategy-owned transcript scopes."
  @spec capture_canonical_message(Facts.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def capture_canonical_message(facts, message_attrs, source_context),
    do: TranscriptHistory.capture(facts, message_attrs, source_context)

  @doc "Reads a bounded, sanitized transcript projection for an authorized Person only."
  @spec list_canonical_messages(Person.t() | nil, term(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_canonical_messages(person, transcript_id, opts \\ []),
    do: TranscriptHistory.list(person, transcript_id, opts)

  @doc """
  Lists transcripts by literal Person ownership, in ID order, without alias inference.

  `lock: true` requires an existing transaction and locks rows for update.
  `allow_missing_table: true` is reserved for historical migration compatibility;
  only an absent table yields an empty list, not other database errors.
  """
  @spec list_owned_transcripts([pos_integer()], keyword()) :: [Transcript.t()]
  def list_owned_transcripts(person_ids, opts \\ []) do
    query =
      from t in Transcript,
        where: t.owner_person_id in ^person_ids,
        order_by: t.id

    list_ownership_rows(query, "transcripts", person_ids, opts)
  end

  @doc """
  Lists private executions by literal Person ownership, in ID order.

  Supports the same transaction-required `lock` and historical-migration
  `allow_missing_table` options as `list_owned_transcripts/2`.
  """
  @spec list_person_executions([pos_integer()], keyword()) :: [ExecutionRecord.t()]
  def list_person_executions(person_ids, opts \\ []) do
    query =
      from e in ExecutionRecord,
        where: e.person_id in ^person_ids,
        order_by: e.id

    list_ownership_rows(query, "execution_records", person_ids, opts)
  end

  defp list_ownership_rows(query, table, person_ids, opts) do
    lock? = Keyword.get(opts, :lock, false)

    if lock? and not Repo.in_transaction?() do
      raise ArgumentError, "ownership row locking requires a transaction"
    end

    cond do
      person_ids == [] -> []
      Keyword.get(opts, :allow_missing_table, false) and not ownership_table_exists?(table) -> []
      lock? -> query |> lock("FOR UPDATE") |> Repo.all()
      true -> Repo.all(query)
    end
  end

  defp ownership_table_exists?(table) do
    %{rows: [[relation]]} = Repo.query!("SELECT to_regclass($1)", [table], log: false)
    not is_nil(relation)
  end

  @doc "Validates transcript ownership without changing its scope or permission resource."
  @spec change_transcript_owner(Transcript.t(), pos_integer()) :: Ecto.Changeset.t()
  def change_transcript_owner(%Transcript{} = transcript, person_id),
    do: Transcript.changeset(transcript, %{owner_person_id: person_id})

  @doc "Updates transcript ownership without changing its scope or permission resource."
  @spec update_transcript_owner(Transcript.t(), pos_integer()) ::
          {:ok, Transcript.t()} | {:error, Ecto.Changeset.t()}
  def update_transcript_owner(%Transcript{} = transcript, person_id) do
    transcript
    |> change_transcript_owner(person_id)
    |> Repo.update()
  end

  @doc "Validates private execution ownership without changing its messages or capability."
  @spec change_execution_owner(ExecutionRecord.t(), pos_integer()) :: Ecto.Changeset.t()
  def change_execution_owner(%ExecutionRecord{} = execution, person_id),
    do: ExecutionRecord.changeset(execution, %{person_id: person_id})

  @doc "Updates private execution ownership without changing its messages or capability."
  @spec update_execution_owner(ExecutionRecord.t(), pos_integer()) ::
          {:ok, ExecutionRecord.t()} | {:error, Ecto.Changeset.t()}
  def update_execution_owner(%ExecutionRecord{} = execution, person_id) do
    execution
    |> change_execution_owner(person_id)
    |> Repo.update()
  end

  # ── Conversations ──────────────────────────────────────────────────

  @doc "Creates a new conversation."
  def create_conversation(attrs) do
    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Fetches a conversation by id, returns nil if not found."
  def get_conversation(id), do: Repo.get(Conversation, id)

  @doc "Fetches by UUID and literal Person owner, without identity inference or alias fallback."
  @spec get_person_conversation(term(), term(), keyword()) :: struct() | nil
  def get_person_conversation(id, person_id, opts \\ [])

  def get_person_conversation(id, person_id, opts) when is_integer(person_id) and person_id > 0 do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        query = from c in Conversation, where: c.id == ^uuid and c.person_id == ^person_id
        query = if opts[:lock], do: lock(query, "FOR UPDATE"), else: query
        Repo.one(query)

      _ ->
        nil
    end
  end

  def get_person_conversation(_, _, _), do: nil

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
  - `preload` — associations needed by the caller; defaults to `[:person, :user]`.
  """
  def list_conversations(opts \\ []) do
    opts
    |> conversation_query()
    |> Repo.all()
    |> backfill_missing_person_ids()
    |> Repo.preload(Keyword.get(opts, :preload, [:person, :user]))
  end

  @doc "Counts the exact listing scope in SQL, ignoring pagination."
  @spec count_conversations(keyword()) :: non_neg_integer()
  def count_conversations(opts \\ []) do
    opts
    |> Keyword.drop([:limit, :offset])
    |> conversation_query()
    |> exclude(:order_by)
    |> Repo.aggregate(:count)
  end

  defp conversation_query(opts) do
    search_in = Keyword.get(opts, :search_in, :all)
    query = from(c in Conversation, order_by: [desc: c.updated_at, desc: c.id])

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
  Resolves the canonical conversation and persists an incoming user message before execution.

  The returned IDs are trusted Engine references. When the provider supplies a message ID,
  redelivery within the same conversation reuses the previously admitted message.
  """
  @spec admit_incoming(Incoming.t()) ::
          {:ok,
           %{
             conversation_id: Ecto.UUID.t(),
             user_message_id: Ecto.UUID.t(),
             admitted?: boolean(),
             finalization_token: String.t() | nil
           }}
          | {:error, term()}
  def admit_incoming(%Incoming{routing_context: %{source_scope: :invalid}}),
    do: {:error, :invalid_history_source}

  def admit_incoming(%Incoming{routing_context: %{conversation_type: nil}} = msg),
    do: admit_unlocked(msg, :none)

  def admit_incoming(%Incoming{message_id: id} = msg) when is_binary(id) and id != "" do
    Repo.transaction(fn ->
      lock_admission_source(msg)
      source = canonical_admission_source(msg)

      result =
        case source do
          {:ok, _provider, _account_key} -> admit_unlocked(msg, source)
          :none -> admit_unlocked(msg, source)
          {:error, _} = error -> error
        end

      case result do
        {:ok, admitted} -> admitted
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def admit_incoming(%Incoming{} = msg), do: admit_unlocked(msg, :none)

  defp lock_admission_source(%Incoming{message_id: id, routing_context: context} = msg) do
    if is_binary(id) and id != "" and not is_nil(context.conversation_type) and
         is_integer(context.channel_config_id) and context.channel_config_id > 0 and
         SourceIdentity.valid_scope?(context.source_scope) do
      TranscriptHistory.lock_source_identity(
        to_string(msg.provider),
        context.channel_config_id,
        %{source_scope: context.source_scope},
        %{external_message_id: id}
      )
    end
  end

  defp admit_unlocked(msg, source) do
    identity = conversation_identity(msg)
    channel_user_id = identity.conversation_key || identity.participant_id || msg.author_id

    with {:ok, conv} <- conversation_for_persistence(msg, channel_user_id, identity),
         {:ok, conv} <- maybe_store_author_id(conv, msg.author_id),
         {:ok, conv} <- maybe_assign_person(conv, Incoming.person_id(msg)),
         {:ok, {user_message, admitted?, finalization_token}} <-
           get_or_insert_admitted_message(conv, msg, source) do
      {:ok,
       %{
         conversation_id: conv.id,
         user_message_id: user_message.id,
         admitted?: admitted?,
         finalization_token: finalization_token
       }}
    end
  end

  defp get_or_insert_admitted_message(%Conversation{} = conv, %Incoming{} = msg, source) do
    case admitted_message(conv.id, msg.message_id) do
      %Message{} = message ->
        if matching_admitted_replay?(message, msg),
          do: {:ok, {message, false, nil}},
          else: {:error, :source_conflict}

      nil ->
        case adopt_canonical_message(conv, msg, source) do
          :none -> insert_admitted_message(conv, msg)
          result -> result
        end
    end
  end

  defp matching_admitted_replay?(message, msg) do
    expected_source =
      case normalized_history_source(msg) do
        {:ok, source} -> source
        :error -> nil
      end

    message.role == "user" and message.content == (msg.content || "") and
      message.author_id == msg.author_id and
      Map.get(message.metadata || %{}, "history_source") == expected_source
  end

  defp adopt_canonical_message(conv, msg, source) do
    case source do
      {:ok, provider, account_key} ->
        maybe_attach_canonical_admission(conv, msg, provider, account_key)

      _ ->
        :none
    end
  end

  defp maybe_attach_canonical_admission(conv, msg, provider, account_key) do
    case Repo.get_by(Message,
           source_provider: provider,
           source_account_key: account_key,
           external_message_id: msg.message_id
         ) do
      %Message{} = canonical -> attach_canonical_in_transaction(conv, msg, canonical.id)
      nil -> :none
    end
  end

  defp attach_canonical_in_transaction(conv, msg, id) do
    Repo.transaction(fn ->
      locked = Repo.one(from m in Message, where: m.id == ^id, lock: "FOR UPDATE")

      case attach_canonical_admission(conv, msg, locked) do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp canonical_admission_source(%Incoming{message_id: id, routing_context: context} = msg)
       when is_binary(id) and id != "" do
    provider = to_string(msg.provider)
    config_id = context.channel_config_id
    {:ok, kind} = CommunicationPolicy.kind(msg)

    source_scope = context.source_scope

    with {:ok, _} <- Facts.strategy(%Facts{provider: provider, kind: kind}),
         true <- is_integer(config_id) and config_id > 0,
         true <- SourceIdentity.valid_scope?(source_scope),
         true <- kind != :replicated or (is_binary(source_scope) and source_scope != ""),
         %ChannelConfig{provider: ^provider, kind: "retrieval", enabled: true, archived_at: nil} =
           config <-
           Repo.get(ChannelConfig, config_id),
         true <- kind != :replicated or match?({:ok, _}, normalized_history_source(msg, config)) do
      {:ok, provider, SourceIdentity.account_key(provider, config_id, source_scope)}
    else
      _ -> {:error, :invalid_history_source}
    end
  end

  defp canonical_admission_source(_msg), do: :none

  defp attach_canonical_admission(conv, msg, %Message{} = message) do
    cond do
      not matching_canonical_admission?(message, msg) ->
        {:error, :source_conflict}

      message.role == "user" and message.conversation_id == conv.id ->
        {:ok, {message, false, nil}}

      message.role != "external" or not is_nil(message.conversation_id) ->
        {:error, :source_conflict}

      true ->
        adopt_canonical_user_turn(conv, msg, message)
    end
  end

  defp attach_canonical_admission(_conv, _msg, nil), do: {:error, :source_conflict}

  defp matching_canonical_admission?(message, msg) do
    message.content == msg.content and message.author_id == msg.author_id and
      matching_canonical_placement?(message.id, msg)
  end

  defp matching_canonical_placement?(message_id, msg) do
    {:ok, kind} = CommunicationPolicy.kind(msg)
    facts = %Facts{provider: to_string(msg.provider), kind: kind}

    case Facts.strategy(facts) do
      {:ok, kind} ->
        strategy = Atom.to_string(kind)

        thread_scope =
          case kind do
            :shared -> msg.thread_id
            :replicated -> msg.routing_context.conversation_id
            _ -> nil
          end

        message_id
        |> canonical_placements(msg, strategy)
        |> scope_admission_thread(thread_scope)
        |> Repo.exists?()

      _ ->
        false
    end
  end

  defp canonical_placements(message_id, msg, strategy) do
    channel_id =
      if strategy == "replicated",
        do: msg.routing_context.conversation_id || msg.channel_id,
        else: msg.channel_id

    from placement in TranscriptMessage,
      join: transcript in Transcript,
      on: transcript.id == placement.transcript_id,
      where:
        placement.message_id == ^message_id and
          transcript.external_channel_id == ^channel_id and
          transcript.channel_config_id == ^msg.routing_context.channel_config_id and
          transcript.provider == ^to_string(msg.provider) and
          transcript.strategy == ^strategy
  end

  defp scope_admission_thread(query, nil),
    do: where(query, [_, transcript], is_nil(transcript.external_thread_id))

  defp scope_admission_thread(query, thread_id),
    do: where(query, [_, transcript], transcript.external_thread_id == ^thread_id)

  defp adopt_canonical_user_turn(conv, msg, message) do
    token = Ecto.UUID.generate()

    metadata =
      (message.metadata || %{})
      |> Map.merge(incoming_attachment_metadata(msg))
      |> Map.put("execution_status", "pending")
      |> Map.put("finalization_token_hash", finalization_token_hash(token))
      |> maybe_put_external_message_id(msg.message_id)
      |> maybe_put_history_source(msg)

    message
    |> Message.changeset(%{
      conversation_id: conv.id,
      role: "user",
      content: msg.content,
      metadata: metadata
    })
    |> Repo.update()
    |> case do
      {:ok, admitted} ->
        after_message_insert(conv, admitted)
        {:ok, {admitted, true, token}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_admitted_message(conv, msg) do
    finalization_token = Ecto.UUID.generate()

    metadata =
      msg
      |> incoming_attachment_metadata()
      |> Map.put("execution_status", "pending")
      |> Map.put("finalization_token_hash", finalization_token_hash(finalization_token))
      |> maybe_put_external_message_id(msg.message_id)
      |> maybe_put_history_source(msg)

    conv
    |> add_message(%{
      role: "user",
      content: msg.content || "",
      author_id: msg.author_id,
      provider_sent_at: msg.routing_context.provider_sent_at,
      metadata: metadata
    })
    |> case do
      {:ok, message} -> {:ok, {message, true, finalization_token}}
      error -> error
    end
    |> recover_admitted_message_conflict(conv.id, msg)
  end

  defp recover_admitted_message_conflict(
         {:error, %Ecto.Changeset{} = changeset} = error,
         conversation_id,
         %Incoming{} = incoming
       ) do
    if Keyword.has_key?(changeset.errors, :metadata) do
      recover_existing_admission(conversation_id, incoming, error)
    else
      error
    end
  end

  defp recover_admitted_message_conflict(result, _conversation_id, _incoming),
    do: result

  defp recover_existing_admission(conversation_id, incoming, error) do
    case admitted_message(conversation_id, incoming.message_id) do
      %Message{} = message ->
        if matching_admitted_replay?(message, incoming),
          do: {:ok, {message, false, nil}},
          else: {:error, :source_conflict}

      nil ->
        error
    end
  end

  defp admitted_message(_conversation_id, nil), do: nil
  defp admitted_message(_conversation_id, ""), do: nil

  defp admitted_message(conversation_id, external_message_id) do
    external_message_id = to_string(external_message_id)

    Repo.one(
      from m in Message,
        where:
          m.conversation_id == ^conversation_id and m.role == "user" and
            fragment("?->>'external_message_id' = ?", m.metadata, ^external_message_id),
        limit: 1
    )
  end

  defp maybe_put_external_message_id(metadata, nil), do: metadata
  defp maybe_put_external_message_id(metadata, ""), do: metadata

  defp maybe_put_external_message_id(metadata, external_message_id),
    do: Map.put(metadata, "external_message_id", to_string(external_message_id))

  defp maybe_put_history_source(metadata, incoming) do
    case normalized_history_source(incoming) do
      {:ok, source} -> Map.put(metadata, "history_source", source)
      :error -> metadata
    end
  end

  defp normalized_history_source(incoming, config \\ nil)

  defp normalized_history_source(
         %Incoming{
           provider: provider,
           channel_id: channel_id,
           author_id: author_id,
           routing_context:
             %{
               channel_config_id: config_id,
               conversation_type: :recipient_addressed,
               source_scope: scope,
               audience: %Audience{sender: sender} = audience
             } = context
         },
         config
       ) do
    provider = to_string(provider)

    with true <- is_binary(scope) and scope != "" and byte_size(scope) <= 255,
         true <- sender == author_id,
         %Audience{} <- Audience.normalize(audience),
         %ChannelConfig{
           provider: ^provider,
           kind: "retrieval",
           enabled: true,
           archived_at: nil
         } <-
           config || Repo.get(ChannelConfig, config_id) do
      {:ok,
       %{
         "provider" => provider,
         "channel_config_id" => config_id,
         "channel_id" => context.conversation_id || channel_id,
         "source_scope" => scope
       }}
    else
      _ -> :error
    end
  end

  defp normalized_history_source(_incoming, _config), do: :error

  @doc """
  Finalizes a handled Agent outcome against its previously admitted user message.

  Successful outcomes add one assistant message. Failed outcomes retain their trace and
  safe diagnostics on the user message without introducing an assistant turn into history.
  """
  @spec finalize_incoming(Ecto.UUID.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def finalize_incoming(user_message_id, finalization_token, result, opts \\ [])

  def finalize_incoming(user_message_id, finalization_token, result, opts)
      when is_binary(user_message_id) and is_binary(finalization_token) and is_map(result) and
             is_list(opts) do
    with {:ok, artifacts} <- prepare_trace_artifacts(result, opts) do
      Repo.transaction(fn ->
        finalize_transaction(user_message_id, finalization_token, result, artifacts, opts)
      end)
      |> complete_finalization()
    end
  end

  def finalize_incoming(_user_message_id, _finalization_token, _result, _opts),
    do: {:error, :invalid_finalization}

  defp complete_finalization({:ok, %{assistant_message: %Message{} = assistant} = finalized}) do
    after_message_insert(get_conversation(assistant.conversation_id), assistant)
    {:ok, Map.delete(finalized, :assistant_message)}
  end

  defp complete_finalization({:ok, finalized}), do: {:ok, finalized}

  defp complete_finalization({:error, reason}),
    do: {:error, normalize_artifact_error(reason)}

  defp finalize_transaction(user_message_id, finalization_token, result, artifacts, opts) do
    case lock_admitted_message(user_message_id) do
      nil ->
        Repo.rollback(:user_message_not_found)

      %Message{} = user_message ->
        if valid_finalization_token?(user_message, finalization_token) do
          finalize_locked_message(user_message, result, artifacts, opts)
        else
          Repo.rollback(:invalid_finalization_token)
        end
    end
  end

  defp finalization_token_hash(token),
    do: token |> then(&:crypto.hash(:sha256, &1)) |> Base.encode64()

  defp valid_finalization_token?(user_message, token) do
    expected_hash = Map.get(user_message.metadata || %{}, "finalization_token_hash")
    is_binary(expected_hash) and expected_hash == finalization_token_hash(token)
  end

  defp lock_admitted_message(user_message_id) do
    Repo.one(
      from m in Message,
        where: m.id == ^user_message_id and m.role == "user",
        lock: "FOR UPDATE"
    )
  end

  defp finalize_locked_message(%Message{} = user_message, result, artifacts, opts) do
    case Map.get(user_message.metadata || %{}, "execution_status") do
      status when status in ["completed", "failed"] ->
        finalized_result(user_message)

      "pending" ->
        if failed_execution?(result) do
          finalize_failed_message(user_message, result, artifacts, opts)
        else
          finalize_successful_message(user_message, result, artifacts, opts)
        end

      _ ->
        Repo.rollback(:message_not_admitted)
    end
  end

  defp finalize_successful_message(user_message, result, artifacts, opts) do
    %{body: assistant_body, sources: assistant_sources} = normalize_assistant_response(result)

    with {:ok, user_message} <- update_execution_message(user_message, result, "completed", []),
         assistant_attrs <-
           result
           |> assistant_message_attrs(assistant_body, assistant_sources, artifacts)
           |> update_in(
             [:metadata],
             &Map.put(&1 || %{}, "in_reply_to_message_id", user_message.id)
           ),
         {:ok, assistant_message} <-
           Repo.insert(
             message_changeset(%Conversation{id: user_message.conversation_id}, assistant_attrs)
           ),
         {:ok, _artifacts} <-
           insert_trace_artifacts(Repo, assistant_message, artifacts, artifact_max_bytes(opts)) do
      %{
        conversation_id: user_message.conversation_id,
        user_message_id: user_message.id,
        assistant_message_id: assistant_message.id,
        assistant_message: assistant_message
      }
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp finalize_failed_message(user_message, result, artifacts, opts) do
    trace = assistant_trace(result, artifacts)

    with {:ok, user_message} <- update_execution_message(user_message, result, "failed", trace),
         {:ok, _artifacts} <-
           insert_trace_artifacts(Repo, user_message, artifacts, artifact_max_bytes(opts)) do
      %{
        conversation_id: user_message.conversation_id,
        user_message_id: user_message.id,
        assistant_message_id: nil
      }
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_execution_message(user_message, result, status, trace) do
    metadata =
      (user_message.metadata || %{})
      |> Map.put("execution_status", status)
      |> Map.put("execution", execution_metadata(result))

    user_message
    |> Message.changeset(%{metadata: metadata, trace: trace})
    |> Repo.update()
  end

  defp execution_metadata(result) do
    ~w(error error_type error_recovery error_retryable reason termination_reason model provider agent)a
    |> Enum.reduce(%{}, fn key, metadata ->
      case map_get(result, Atom.to_string(key)) do
        nil -> metadata
        value -> Map.put(metadata, Atom.to_string(key), value)
      end
    end)
    |> StreamEvents.json_safe()
  end

  defp failed_execution?(result) do
    map_get(result, "error") == true or map_get(result, "suppressed") == true
  end

  defp finalized_result(user_message) do
    assistant =
      Repo.one(
        from m in Message,
          where:
            m.conversation_id == ^user_message.conversation_id and m.role == "assistant" and
              fragment("?->>'in_reply_to_message_id' = ?", m.metadata, ^user_message.id),
          limit: 1
      )

    %{
      conversation_id: user_message.conversation_id,
      user_message_id: user_message.id,
      assistant_message_id: assistant && assistant.id
    }
  end

  defp assistant_message_attrs(result, assistant_body, assistant_sources, artifacts) do
    %{
      role: "assistant",
      content: assistant_body,
      confidence_score: map_get(result, "confidence_score"),
      latency_ms: map_get(result, "latency_ms"),
      prompt_tokens: map_get(result, "prompt_tokens"),
      completion_tokens: map_get(result, "completion_tokens"),
      total_tokens: map_get(result, "total_tokens"),
      model: map_get(result, "model"),
      sources: assistant_sources,
      metadata: assistant_metadata(result),
      trace: assistant_trace(result, artifacts)
    }
  end

  defp prepare_trace_artifacts(result, opts) when is_map(result) do
    result
    |> Map.get(:trace_artifacts, Map.get(result, "trace_artifacts", []))
    |> normalize_trace_artifacts(artifact_max_bytes(opts))
  end

  defp normalize_trace_artifacts(nil, _max_bytes), do: {:ok, []}

  defp normalize_trace_artifacts(artifacts, max_bytes) when is_list(artifacts) do
    Enum.reduce_while(artifacts, {:ok, []}, fn artifact, {:ok, normalized} ->
      with {:ok, artifact} <- normalize_trace_artifact(artifact),
           true <- artifact.size <= max_bytes do
        {:cont, {:ok, [artifact | normalized]}}
      else
        false -> {:halt, {:error, :trace_artifact_too_large}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, artifacts} -> {:ok, Enum.reverse(artifacts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_trace_artifacts(_artifacts, _max_bytes), do: {:error, :invalid_trace_artifact}

  defp normalize_trace_artifact(artifact) when is_map(artifact) do
    content = map_get(artifact, "content")
    tool_call_id = map_get(artifact, "tool_call_id")
    tool_name = map_get(artifact, "tool_name")
    name = map_get(artifact, "name")
    mime_type = map_get(artifact, "mime_type")

    if is_binary(content) and present_binary?(tool_call_id) and present_binary?(tool_name) and
         present_binary?(name) and present_binary?(mime_type) do
      {:ok,
       %{
         id: Ecto.UUID.generate(),
         content: content,
         size: byte_size(content),
         sha256: :crypto.hash(:sha256, content),
         tool_call_id: tool_call_id,
         tool_name: tool_name,
         name: name,
         mime_type: mime_type,
         record: map_get(artifact, "record") || %{}
       }}
    else
      {:error, :invalid_trace_artifact}
    end
  end

  defp normalize_trace_artifact(_artifact), do: {:error, :invalid_trace_artifact}

  defp insert_trace_artifacts(repo, assistant_message, artifacts, max_bytes) do
    Enum.reduce_while(artifacts, {:ok, []}, fn artifact, {:ok, inserted} ->
      changeset =
        %MessageTraceArtifact{id: artifact.id, message_id: assistant_message.id}
        |> MessageTraceArtifact.changeset(Map.delete(artifact, :id), max_bytes)

      case repo.insert(changeset) do
        {:ok, row} -> {:cont, {:ok, [row | inserted]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp artifact_max_bytes(opts) do
    case Keyword.get(opts, :artifact_max_bytes) do
      max_bytes when is_integer(max_bytes) and max_bytes > 0 ->
        max_bytes

      _ ->
        case Zaq.Config.get(:zaq, :message_trace_artifact_max_bytes, 100 * 1024 * 1024, opts) do
          max_bytes when is_integer(max_bytes) and max_bytes > 0 -> max_bytes
          _ -> 100 * 1024 * 1024
        end
    end
  end

  defp normalize_artifact_error(%Ecto.Changeset{} = changeset), do: changeset
  defp normalize_artifact_error(reason), do: reason

  defp present_binary?(value), do: is_binary(value) and value != ""

  @doc """
  Persists one message into the conversation resolved from an incoming routing envelope.

  This stores exactly one message and defaults
  the message role to `"assistant"`, which supports assistant-initiated follow-ups
  or notifications without fabricating a user turn.
  """
  def persist_message_history(%Incoming{} = msg, attrs) when is_map(attrs) do
    identity = conversation_identity(msg)

    channel_user_id =
      identity.conversation_key || identity.participant_id || msg.author_id || msg.channel_id

    message_attrs = message_history_attrs(attrs, msg)

    with {:ok, conv} <- conversation_for_persistence(msg, channel_user_id, identity),
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
        conversation_identity_from_stamp(channel_type, identity)

      _ ->
        unscoped_conversation_identity(default_channel_type(msg.provider))
    end
  end

  defp conversation_identity_from_stamp(channel_type, identity) do
    conversation_key = ConversationIdentity.identifier(identity, "key")
    external_channel_id = ConversationIdentity.identifier(identity, "channel_id")
    participant_id = ConversationIdentity.identifier(identity, "participant_id")

    %{
      channel_type: channel_type,
      conversation_key: conversation_key,
      channel_config_id: ConversationIdentity.channel_config_id(identity),
      external_channel_id: external_channel_id,
      external_thread_id: ConversationIdentity.identifier(identity, "thread_id"),
      participant_id: participant_id,
      scoped?:
        identity["scoped"] == true and is_nil(conversation_key) and
          not is_nil(external_channel_id) and not is_nil(participant_id)
    }
  end

  defp unscoped_conversation_identity(channel_type) do
    %{
      channel_type: channel_type,
      conversation_key: nil,
      channel_config_id: nil,
      external_channel_id: nil,
      external_thread_id: nil,
      participant_id: nil,
      scoped?: false
    }
  end

  defp default_channel_type(nil), do: "api"

  defp default_channel_type(provider) when is_atom(provider),
    do: default_channel_type(Atom.to_string(provider))

  defp default_channel_type("web"), do: "bo"
  defp default_channel_type(provider) when is_binary(provider), do: provider
  defp default_channel_type(_provider), do: "api"

  defp conversation_for_persistence(msg, channel_user_id, identity) do
    case metadata_conversation_id(msg.metadata) do
      id when is_binary(id) and id != "" ->
        case get_conversation(id) do
          %Conversation{} = conv -> validate_conversation_scope(conv, channel_user_id, identity)
          nil -> {:error, :conversation_not_found}
        end

      _ ->
        get_or_create_conversation_for_identity(channel_user_id, identity)
    end
  end

  defp validate_conversation_scope(
         %Conversation{} = conversation,
         channel_user_id,
         %{scoped?: true} = identity
       ) do
    if conversation.channel_type == identity.channel_type and
         conversation.channel_user_id == channel_user_id and
         conversation.channel_config_id == identity.channel_config_id and
         conversation.external_channel_id == identity.external_channel_id and
         conversation.external_thread_id == identity.external_thread_id do
      {:ok, conversation}
    else
      {:error, :conversation_scope_mismatch}
    end
  end

  defp validate_conversation_scope(%Conversation{} = conversation, _channel_user_id, _identity),
    do: {:ok, conversation}

  defp get_or_create_conversation_for_identity(channel_user_id, %{scoped?: true} = identity) do
    query = communication_scope_query(channel_user_id, identity)

    case Repo.one(query) do
      %Conversation{} = conversation ->
        {:ok, conversation}

      nil ->
        attrs = %{
          channel_user_id: channel_user_id,
          channel_type: identity.channel_type,
          channel_config_id: identity.channel_config_id,
          external_channel_id: identity.external_channel_id,
          external_thread_id: identity.external_thread_id
        }

        case create_conversation(attrs) do
          {:ok, conversation} -> {:ok, conversation}
          {:error, %Ecto.Changeset{} = changeset} -> recover_scope_conflict(changeset, query)
        end
    end
  end

  defp get_or_create_conversation_for_identity(channel_user_id, identity) do
    get_or_create_conversation_for_channel(channel_user_id, identity.channel_type, nil)
  end

  defp communication_scope_query(channel_user_id, identity) do
    query =
      from c in Conversation,
        where:
          c.channel_user_id == ^channel_user_id and
            c.channel_type == ^identity.channel_type and
            c.external_channel_id == ^identity.external_channel_id and
            c.status == "active",
        limit: 1

    query
    |> scope_nullable_field(:channel_config_id, identity.channel_config_id)
    |> scope_nullable_field(:external_thread_id, identity.external_thread_id)
  end

  defp scope_nullable_field(query, field, nil), do: where(query, [c], is_nil(field(c, ^field)))

  defp scope_nullable_field(query, field, value),
    do: where(query, [c], field(c, ^field) == ^value)

  defp recover_scope_conflict(changeset, query) do
    if Keyword.has_key?(changeset.errors, :channel_user_id) do
      case Repo.one(query) do
        %Conversation{} = conversation -> {:ok, conversation}
        nil -> {:error, changeset}
      end
    else
      {:error, changeset}
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
      "provider" => Map.get(result, :provider) || Map.get(result, "provider"),
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

  defp assistant_trace(result, artifacts) do
    artifacts_by_tool_call = Enum.group_by(artifacts, & &1.tool_call_id)

    result
    |> assistant_trace()
    |> Enum.map(fn entry ->
      tool_call_id = Map.get(entry, "id") || Map.get(entry, :id)

      case Map.get(artifacts_by_tool_call, tool_call_id, []) do
        [] -> entry
        matches -> Map.put(entry, "artifacts", Enum.map(matches, &artifact_descriptor/1))
      end
    end)
  end

  defp artifact_descriptor(artifact) do
    %{
      "id" => artifact.id,
      "name" => artifact.name,
      "mime_type" => artifact.mime_type,
      "size" => artifact.size
    }
  end

  defp message_history_attrs(attrs, %Incoming{} = incoming) do
    metadata =
      attrs
      |> map_get("metadata")
      |> then(&if(is_map(&1), do: &1, else: %{}))
      |> merge_incoming_attachments(incoming)

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
      metadata: StreamEvents.json_safe(metadata),
      trace: (map_get(attrs, "trace") || []) |> StreamEvents.json_safe()
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp incoming_attachment_metadata(%Incoming{attachments: attachments})
       when is_list(attachments) and attachments != [] do
    %{"attachments" => Enum.map(attachments, &Zaq.Contracts.Record.metadata/1)}
  end

  defp incoming_attachment_metadata(%Incoming{}), do: %{}

  defp merge_incoming_attachments(metadata, %Incoming{} = incoming) do
    case incoming_attachment_metadata(incoming) do
      %{"attachments" => attachments} -> Map.put(metadata, "attachments", attachments)
      %{} -> metadata
    end
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
    result =
      conversation
      |> message_changeset(attrs)
      |> Repo.insert()

    with {:ok, msg} <- result do
      after_message_insert(conversation, msg)
      {:ok, msg}
    end
  end

  defp message_changeset(%Conversation{} = conversation, attrs) do
    attrs_with_id = Map.put(attrs, :conversation_id, conversation.id)
    Message.changeset(%Message{}, attrs_with_id)
  end

  defp after_message_insert(%Conversation{} = conversation, %Message{} = message) do
    touch_conversation(conversation)
    maybe_record_message_telemetry(conversation, message)

    if message.role == "assistant" do
      enqueue_token_aggregator(conversation.id, message)
    end

    if message.role == "user" && is_nil(conversation.title) do
      maybe_generate_title(conversation, message.content)
    end

    :ok
  end

  @doc """
  Returns messages for a conversation in insertion order.

  Options:
  - `:limit` — cap the number of rows at the database level (`LIMIT`). With the
    ascending `inserted_at` order this returns the oldest `n` messages — pushing
    the truncation into SQL instead of fetching every row and trimming in memory.
  """
  def list_messages(%Conversation{} = conversation, opts \\ []) do
    ratings =
      case Keyword.fetch(opts, :rating_person_id) do
        {:ok, id} when is_integer(id) and id > 0 ->
          from r in MessageRating, where: r.person_id == ^id

        {:ok, _} ->
          from r in MessageRating, where: false

        :error ->
          from(r in MessageRating)
      end

    from(m in Message,
      where: m.conversation_id == ^conversation.id,
      order_by: [asc: m.inserted_at, asc: m.id],
      preload: [ratings: ^ratings]
    )
    |> maybe_limit(opts[:limit])
    |> Repo.all()
  end

  @doc "Fetches a message only within its supplied conversation parent."
  @spec get_conversation_message(struct(), term(), keyword()) :: struct() | nil
  def get_conversation_message(%Conversation{id: parent}, id, opts \\ []) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        query = from m in Message, where: m.id == ^uuid and m.conversation_id == ^parent
        query = if opts[:lock], do: lock(query, "FOR UPDATE"), else: query
        Repo.one(query)

      _ ->
        nil
    end
  end

  @doc "Fetches a share only within its supplied conversation parent."
  @spec get_conversation_share(struct(), term()) :: struct() | nil
  def get_conversation_share(%Conversation{id: parent}, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Repo.one(
          from s in ConversationShare, where: s.id == ^uuid and s.conversation_id == ^parent
        )

      _ ->
        nil
    end
  end

  @doc "Fetches a trace artifact only within its supplied message parent."
  @spec get_message_trace_artifact(struct(), term()) :: struct() | nil
  def get_message_trace_artifact(%Message{id: parent}, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Repo.one(from a in MessageTraceArtifact, where: a.id == ^uuid and a.message_id == ^parent)

      _ ->
        nil
    end
  end

  @doc "Returns a trace artifact when the BO user may access its conversation."
  @spec get_authorized_trace_artifact(String.t(), User.t()) ::
          {:ok, map()} | {:error, :not_found}
  def get_authorized_trace_artifact(artifact_id, %User{} = user) when is_binary(artifact_id) do
    with {:ok, artifact_id} <- Ecto.UUID.cast(artifact_id),
         %MessageTraceArtifact{} = artifact <-
           Repo.one(authorized_trace_artifact_query(artifact_id, user)) do
      {:ok,
       %{
         id: artifact.id,
         content: artifact.content,
         name: artifact.name,
         mime_type: artifact.mime_type,
         size: artifact.size,
         sha256: artifact.sha256
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  def get_authorized_trace_artifact(_artifact_id, _user), do: {:error, :not_found}

  defp authorized_trace_artifact_query(artifact_id, %{id: user_id} = user) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    base_query =
      from artifact in MessageTraceArtifact,
        join: message in Message,
        on: message.id == artifact.message_id,
        join: conversation in Conversation,
        on: conversation.id == message.conversation_id,
        where: artifact.id == ^artifact_id

    if super_admin?(user) do
      base_query
    else
      from [artifact, _message, conversation] in base_query,
        left_join: share in ConversationShare,
        on:
          share.conversation_id == conversation.id and share.shared_with_user_id == ^user_id and
            share.permission == "read" and (is_nil(share.expires_at) or share.expires_at > ^now),
        where: conversation.user_id == ^user_id or not is_nil(share.id),
        select: artifact
    end
  end

  defp super_admin?(%{role: %{name: "super_admin"}}), do: true
  defp super_admin?(_user), do: false

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, n) when is_integer(n), do: limit(query, ^n)

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
        person_id = Map.get(rater_attrs, :person_id) ->
          where(query, [r], r.person_id == ^person_id)

        user_id = Map.get(rater_attrs, :user_id) ->
          where(query, [r], r.user_id == ^user_id)

        channel_user_id = Map.get(rater_attrs, :channel_user_id) ->
          where(query, [r], r.channel_user_id == ^channel_user_id)

        true ->
          where(query, [r], is_nil(r.person_id))
      end

    Repo.one(query)
  end

  @doc "Updates an existing rating; only submitted rating/comment edits emit feedback telemetry."
  def update_rating(%MessageRating{} = rating, attrs, telemetry_attrs \\ %{}, occurred_at \\ nil) do
    rating
    |> MessageRating.changeset(attrs)
    |> Repo.update()
    |> tap(fn
      {:ok, updated} ->
        if Enum.any?([:rating, :comment, "rating", "comment"], &Map.has_key?(attrs, &1)),
          do: maybe_record_rating_telemetry(updated, telemetry_attrs, occurred_at)

      _ ->
        :ok
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

      %Message{conversation_id: nil} ->
        # Canonical messages require an authorized transcript path; this legacy
        # UUID-only rating endpoint cannot establish one.
        {:error, :not_found}

      message ->
        upsert_rating(message, rater_attrs)
    end
  end

  @doc "Upserts feedback for an already-resolved message without an unscoped message reread."
  @spec upsert_rating(struct(), map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def upsert_rating(%Message{} = message, rater_attrs) do
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
        Zaq.Hooks.dispatch_async(
          :feedback_provided,
          %{
            message: message,
            rating: rating,
            conversation_history: list_conversation_messages(message.conversation_id),
            rater_attrs: rater_attrs
          },
          %{}
        )

      _ ->
        :ok
    end)
  end

  @doc "Rates a scoped canonical message from trusted Channels ingress for a resolved provider actor."
  def rate_message_by_source(
        %{
          provider: provider,
          channel_config_id: config_id,
          channel_id: channel_id,
          source_scope: scope,
          message_id: external_id
        } = reference,
        %{channel_user_id: actor_id, rating: rating} = attrs
      )
      when is_binary(provider) and is_integer(config_id) and config_id > 0 and rating in 1..5 do
    with {:scope, true} <-
           {:scope,
            valid_rating_identifiers?([channel_id, external_id, actor_id]) and
              SourceIdentity.valid_scope?(scope)},
         {:connector,
          %ChannelConfig{provider: ^provider, enabled: true, archived_at: nil, kind: "retrieval"}} <-
           {:connector, Repo.get(ChannelConfig, config_id)},
         {:actor, {:ok, %Person{status: "active"} = person}} <-
           {:actor, People.match_by_channel(provider, actor_id, config_id)} do
      Repo.transaction(fn -> rate_source_locked(reference, person, attrs) end)
    else
      {:scope, _} -> {:error, :invalid_source_scope}
      {:connector, _} -> {:error, :invalid_connector}
      {:actor, _} -> {:error, :unresolved_actor}
    end
  end

  def rate_message_by_source(_, _), do: {:error, :invalid_request}

  defp valid_rating_identifiers?(ids), do: Enum.all?(ids, &(is_binary(&1) and &1 != ""))

  defp rate_source_locked(reference, person, attrs) do
    %{
      provider: provider,
      channel_config_id: config_id,
      channel_id: channel_id,
      message_id: external_id
    } = reference

    key = SourceIdentity.account_key(provider, config_id, reference.source_scope)

    message =
      Repo.one(
        from m in Message,
          where:
            m.source_provider == ^provider and
              m.source_account_key == ^key and m.external_message_id == ^external_id,
          lock: "FOR UPDATE"
      )

    with %Message{} <- message,
         {:scope, true} <- {:scope, source_placement?(message, provider, config_id, channel_id)},
         {:ok, saved} <-
           upsert_rating(message, %{
             person_id: person.id,
             rating: attrs.rating,
             comment: attrs[:comment]
           }) do
      saved
    else
      {:error, reason} -> Repo.rollback(reason)
      {:scope, false} -> Repo.rollback(:source_scope_mismatch)
      _ -> Repo.rollback(:not_found)
    end
  end

  # Provider authorization is established at Channels ingress. This checks the
  # event's exact target, not whether the actor may read ZAQ's stored history.
  defp source_placement?(message, provider, config_id, channel_id) do
    Repo.exists?(
      from p in TranscriptMessage,
        join: t in Transcript,
        on: t.id == p.transcript_id,
        where:
          p.message_id == ^message.id and t.provider == ^provider and
            t.channel_config_id == ^config_id and
            t.external_channel_id == ^channel_id,
        select: p.id
    )
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
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    query =
      from share in ConversationShare,
        where:
          share.share_token == ^share_token and
            (is_nil(share.expires_at) or share.expires_at > ^now)

    case Repo.one(query) do
      nil -> nil
      share -> Repo.get(Conversation, share.conversation_id)
    end
  end

  # ── Private ────────────────────────────────────────────────────────

  defp list_conversation_messages(nil), do: []

  defp list_conversation_messages(conversation_id) do
    from(m in Message,
      where: m.conversation_id == ^conversation_id,
      order_by: [asc: m.inserted_at]
    )
    |> Repo.all()
  end

  defp enqueue_token_aggregator(conversation_id, %Message{model: model, inserted_at: inserted_at})
       when is_binary(model) do
    date = inserted_at |> DateTime.to_date() |> Date.to_iso8601()

    %{conversation_id: conversation_id, model: model, date: date}
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

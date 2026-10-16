defmodule Zaq.Engine.Conversations do
  @moduledoc """
  Context module for managing conversations, messages, ratings, and shares.

  Factual capture, provisional execution preparation (`admit_incoming`), execution
  authorization (`admit_execution`), context reads and outcome finalization are
  separate gates. Only execution authorization records admission evidence; a
  prepared binding or stored message is not a permission grant.

  All functions in this module operate on `Zaq.Repo` directly. BO LiveViews
  must call these functions via `Zaq.NodeRouter.dispatch/1` with `%Zaq.Event{}`.
  """

  import Ecto.Query

  alias Zaq.Engine.Conversations.{
    Conversation,
    ConversationShare,
    ExecutionHistory,
    ExecutionLifecycle,
    ExecutionRecord,
    Message,
    MessageAuthor,
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
  alias Zaq.Identity.ExecutionActor
  alias Zaq.People.IdentityResolver
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

  @doc "Verifies the execution binding and reads context with fresh permissions; never records admission."
  @spec execution_history(map(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def execution_history(binding, actor, opts \\ [])

  def execution_history(binding, actor, opts) when is_map(binding) do
    with {:ok, conversation_id} <- Ecto.UUID.cast(binding[:conversation_id]),
         {:ok, input_id} <- Ecto.UUID.cast(binding[:user_message_id]),
         %Message{} = input <- Repo.get(Message, input_id),
         :ok <- verify_execution_binding(input, %{binding | conversation_id: conversation_id}),
         {:ok, conversation, person} <-
           verified_execution_owner(input, actor, binding[:execution_id]) do
      project_execution_history(input, conversation, person, opts)
    else
      _ -> {:error, :unauthorized}
    end
  rescue
    _error in [Ecto.ConstraintError, Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :history_unavailable}
  end

  def execution_history(_binding, _actor, _opts), do: {:error, :unauthorized}

  defp project_execution_history(input, conversation, person, opts) do
    result =
      if Keyword.has_key?(opts, :after_cursors),
        do: ExecutionHistory.delta_admission(input, conversation, person, opts[:after_cursors]),
        else: ExecutionHistory.project_admission(input, conversation, person)

    case result do
      {:error, {:history_access_denied, _}} = denial ->
        if opts[:trusted_access_denial], do: denial, else: {:error, :unauthorized}

      other ->
        other
    end
  end

  @doc "Authorizes one input for execution and records that decision independently of native acceptance."
  def admit_execution(binding, actor, content) when is_map(binding) and is_binary(content) do
    case Ecto.UUID.cast(binding[:user_message_id]) do
      {:ok, input_id} ->
        Repo.transaction(fn -> admit_execution_locked(input_id, binding, actor, content) end)
        |> complete_admission()

      _ ->
        {:error, :unauthorized}
    end
  rescue
    _error in [Ecto.ConstraintError, Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :history_unavailable}
  end

  def admit_execution(_binding, _actor, _content), do: {:error, :unauthorized}

  defp admit_execution_locked(input_id, binding, actor, content) do
    with %Message{} = input <- lock_admitted_message(input_id),
         :ok <- verify_execution_binding(input, binding),
         :ok <- matching_control_content(input, content: content),
         {:ok, conversation, person} <-
           verified_execution_owner(input, actor, binding[:execution_id]) do
      input
      |> ExecutionHistory.project_admission(conversation, person)
      |> with_input_presentation(input)
      |> record_admission(input, binding[:execution_id])
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp with_input_presentation({:ok, projection}, input),
    do: {:ok, Map.put(projection, :input, input_presentation(input))}

  defp with_input_presentation(error, _input), do: error

  defp input_presentation(input) do
    [projected] = MessageAuthor.project([input])
    Map.take(projected, [:id, :role, :content, :author, :timestamp])
  end

  # The caller selects/locks the input. Reads normalize their conversation UUID;
  # authorization retains its existing literal binding comparison under the lock.
  defp verify_execution_binding(%Message{role: "user"} = input, binding) do
    with true <- input.conversation_id == binding[:conversation_id],
         token when is_binary(token) <- binding[:finalization_token],
         true <- valid_finalization_token?(input, token, binding[:execution_id]) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp verify_execution_binding(_input, _binding), do: {:error, :unauthorized}

  # Resolve a fresh active principal once, but compare both record owners. The
  # resulting Person is local to this operation, not a transferable permission.
  defp verified_execution_owner(input, actor, execution_id) do
    with %Conversation{} = conversation <- Repo.get(Conversation, input.conversation_id),
         {:ok, person} <- execution_history_owner(conversation, actor),
         :ok <- ExecutionLifecycle.authorize_resolved_person(input, person, execution_id) do
      {:ok, conversation, person}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp record_admission({:ok, projection}, input, execution_id) do
    with :ok <- ExecutionLifecycle.accept_admission(input, execution_id),
         do: {:ok, projection}
  end

  defp record_admission({:error, {:history_access_denied, _}} = denial, input, execution_id) do
    case ExecutionLifecycle.deny_admission(input, execution_id) do
      {:error, reason} -> Repo.rollback(reason)
      _ -> denial
    end
  end

  defp record_admission(error, _input, _execution_id), do: error

  defp complete_admission({:ok, result}), do: result
  defp complete_admission(error), do: error

  @doc "Revalidates Person request-control authority without exposing admission capabilities."
  def authorize_execution_control(input_id, actor, execution_id \\ nil)

  def authorize_execution_control(input_id, actor, execution_id) when is_binary(input_id) do
    with {:ok, id} <- Ecto.UUID.cast(input_id),
         %Message{} = input <- Repo.get(Message, id),
         {:ok, conversation, person} <- verified_execution_owner(input, actor, execution_id),
         {:ok, _projection} <- ExecutionHistory.project(input, conversation, person) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  def authorize_execution_control(nil, actor, nil) do
    with {:ok, %{person: %{id: id}}} <- ExecutionActor.validate(actor),
         %Person{status: "active"} <- Repo.get(Person, id) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  def authorize_execution_control(_input_id, _actor, _execution_id), do: {:error, :unauthorized}

  @doc "Queues a separately admitted input under the same authorized canonical root."
  def queue_execution_input(root_input_id, binding, actor, opts \\ [])

  def queue_execution_input(root_input_id, binding, actor, opts) when is_map(binding) do
    execution_input_transaction(root_input_id, binding[:user_message_id], fn root, child ->
      with token when is_binary(token) <- binding[:finalization_token],
           true <- valid_finalization_token?(child, token, binding[:execution_id]),
           :ok <- matching_control_content(child, opts),
           {:ok, root_projection} <- execution_scope(root, actor, opts[:root_execution_id]),
           :ok <- ensure_input_admitted(child, binding),
           {:ok, child_projection} <- execution_scope(child, actor, binding[:execution_id]),
           true <- root_projection[:transcript_id] == child_projection[:transcript_id],
           {:ok, receipt} <-
             ExecutionLifecycle.queue(root, child,
               root_execution_id: opts[:root_execution_id],
               execution_id: binding[:execution_id]
             ) do
        Map.put(receipt, :input, input_presentation(child))
      else
        {:closed_before_accept, receipt} -> {:closed_before_accept, receipt}
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:unauthorized)
      end
    end)
    |> committed_input_result(opts)
  end

  def queue_execution_input(_root_input_id, _binding, _actor, _opts), do: {:error, :unauthorized}

  defp committed_input_result({:ok, {:closed_before_accept, receipt}}, opts) do
    if opts[:closed_disposition],
      do: {:error, {:closed_before_accept, receipt}},
      else: {:error, :terminal_request}
  end

  defp committed_input_result(result, _opts), do: result

  defp matching_control_content(child, opts) do
    case Keyword.fetch(opts, :content) do
      :error -> :ok
      {:ok, content} when content == child.content -> :ok
      _ -> {:error, :input_conflict}
    end
  end

  @doc "Records real Jido consumption of a queued input; acknowledgement alone is insufficient."
  def consume_execution_input(root_input_id, child_input_id, actor, opts \\ []) do
    case execution_input_transaction(root_input_id, child_input_id, fn root, child ->
           consume_locked_input(root, child, actor, opts)
         end) do
      {:ok, :ok} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc "Retains rejected queued-input evidence without overwriting proven consumption."
  def reject_execution_input(root_input_id, child_input_id, actor, reason, opts \\ []) do
    case execution_input_transaction(root_input_id, child_input_id, fn root, child ->
           reject_locked_input(root, child, actor, reason, opts)
         end) do
      {:ok, :ok} -> :ok
      {:error, _} = error -> error
    end
  end

  defp reject_locked_input(root, child, actor, reason, opts) do
    with :ok <- ExecutionLifecycle.authorize(root, actor, opts[:root_execution_id]),
         :ok <- ExecutionLifecycle.authorize(child, actor, opts[:execution_id]),
         :ok <- ExecutionLifecycle.reject(root, child, reason, opts) do
      :ok
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp consume_locked_input(root, child, actor, opts) do
    with :ok <- ExecutionLifecycle.authorize(root, actor, opts[:root_execution_id]),
         :ok <- ExecutionLifecycle.authorize(child, actor, opts[:execution_id]),
         :ok <- ExecutionLifecycle.consume(root, child, opts) do
      :ok
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp execution_scope(input, actor, execution_id) do
    case verified_execution_owner(input, actor, execution_id) do
      {:ok, conversation, person} -> ExecutionHistory.scope(input, conversation, person)
      _ -> {:error, :unauthorized}
    end
  end

  defp ensure_input_admitted(input, binding) do
    case ExecutionLifecycle.fetch(input, binding[:execution_id]) do
      {:ok, %ExecutionRecord{admitted_at: %DateTime{}}} -> :ok
      {:ok, _} -> {:error, :admission_required}
      error -> error
    end
  end

  @doc "Prepares one live followup from an authenticated, proven closed-before-accept disposition."
  @spec prepare_execution_followup(map(), map()) ::
          {:ok, map() | :already_prepared} | {:error, term()}
  def prepare_execution_followup(
        %{binding: binding, disposition: :closed_before_accept} = request,
        actor
      )
      when is_map(binding) do
    execution_input_transaction(
      request[:root_user_message_id],
      binding[:user_message_id],
      fn root, input ->
        with token when is_binary(token) <- binding[:finalization_token],
             true <- valid_finalization_token?(input, token, request[:receipt_execution_id]),
             :ok <- matching_control_content(input, content: request[:content]),
             {:ok, prior} <- execution_scope(root, actor, request[:root_execution_id]),
             {:ok, current} <- execution_scope(input, actor, request[:receipt_execution_id]),
             true <- prior[:transcript_id] == current[:transcript_id],
             {:ok, followup} <- ExecutionLifecycle.prepare_followup(input, request, actor) do
          followup
        else
          {:error, reason} -> Repo.rollback(reason)
          _ -> Repo.rollback(:unauthorized)
        end
      end
    )
  end

  def prepare_execution_followup(_, _), do: {:error, :unauthorized}

  defp execution_input_transaction(root_id, child_id, operation) do
    with {:ok, root_id} <- Ecto.UUID.cast(root_id),
         {:ok, child_id} <- Ecto.UUID.cast(child_id),
         true <- root_id != child_id do
      Repo.transaction(fn -> isolated_input_operation(root_id, child_id, operation) end)
      |> complete_input_transaction()
    else
      _ -> {:error, :unauthorized}
    end
  rescue
    _error in [Ecto.ConstraintError, Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :execution_persistence_failed}
  end

  defp complete_input_transaction({:ok, {:persistence_failed, reason}}), do: {:error, reason}
  defp complete_input_transaction(result), do: result

  defp isolated_input_operation(root_id, child_id, operation) do
    # A savepoint must live inside a normal transaction, including for calls on
    # independent connections which have no caller-owned outer transaction.
    Repo.query!("SAVEPOINT zaq_execution_input_operation")

    try do
      result = operate_locked_inputs(root_id, child_id, operation)
      Repo.query!("RELEASE SAVEPOINT zaq_execution_input_operation")
      result
    rescue
      _error in [Ecto.ConstraintError, Postgrex.Error, DBConnection.ConnectionError] ->
        Repo.query!("ROLLBACK TO SAVEPOINT zaq_execution_input_operation")
        Repo.query!("RELEASE SAVEPOINT zaq_execution_input_operation")
        {:persistence_failed, :execution_persistence_failed}
    end
  end

  defp operate_locked_inputs(root_id, child_id, operation) do
    inputs =
      Repo.all(
        from m in Message,
          where: m.id in ^[root_id, child_id] and m.role == "user",
          order_by: m.id,
          lock: "FOR UPDATE"
      )
      |> Map.new(&{&1.id, &1})

    case {inputs[root_id], inputs[child_id]} do
      {%Message{} = root, %Message{} = child} -> operation.(root, child)
      _ -> Repo.rollback(:unauthorized)
    end
  end

  defp execution_history_owner(conversation, actor) do
    case ExecutionActor.validate(actor) do
      {:ok, %{person: %{id: id}}} when id == conversation.person_id and id > 0 ->
        case Repo.get(Person, id) do
          %Person{status: "active"} = person -> {:ok, person}
          _ -> {:error, :unauthorized}
        end

      {:ok, %{kind: kind} = actor} when is_nil(conversation.person_id) ->
        legacy_execution_owner(conversation.user_id, kind, actor)

      _ ->
        {:error, :unauthorized}
    end
  end

  defp legacy_execution_owner(nil, _kind, _actor), do: {:ok, nil}
  defp legacy_execution_owner(id, :bo_user, %{user_id: id}), do: {:ok, nil}
  defp legacy_execution_owner(_id, _kind, _actor), do: {:error, :unauthorized}

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
    do: ExecutionRecord.owner_changeset(execution, person_id)

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

  @doc "Restores a literal Person-owned direct conversation through canonical read authorization."
  def restore_channel_conversation(person, scope, id, page) do
    with :ok <- IdentityResolver.authorize_channel_sender(person, scope) do
      restore_channel_history(person, scope, id, page)
    end
  end

  defp restore_channel_history(person, scope, id, page) when is_list(page) do
    with %Conversation{status: "active", external_thread_id: nil} = conversation <-
           get_person_conversation(id, person.id, []),
         :ok <- channel_conversation_scope(conversation, scope),
         %Transcript{} = transcript <-
           Repo.get_by(scope_nullable_field(Transcript, :external_thread_id, nil),
             provider: conversation.channel_type,
             channel_config_id: conversation.channel_config_id,
             external_channel_id: conversation.external_channel_id,
             strategy: "direct"
           ),
         {:ok, messages} <- list_canonical_messages(person, transcript.id, page) do
      {:ok, %{conversation: conversation, messages: messages}}
    else
      {:error, :unauthorized} -> {:error, :conversation_not_found}
      {:error, :invalid_cursor} = error -> error
      _ -> {:error, :conversation_not_found}
    end
  end

  defp restore_channel_history(_person, _scope, _id, _page), do: {:error, :invalid_cursor}

  defp channel_conversation_scope(conversation, scope) do
    provider = conversation.channel_type

    if conversation.channel_config_id == scope.channel_config_id and
         match?(
           %ChannelConfig{provider: ^provider},
           Repo.get(ChannelConfig, scope.channel_config_id)
         ) and
         present_binary?(conversation.external_channel_id) do
      :ok
    else
      {:error, :conversation_not_found}
    end
  end

  @doc "Binds a verified direct input using ordinary scoped conversation resolution, without preparing execution."
  def prepare_channel_input(person, incoming, initial_context \\ nil)

  def prepare_channel_input(person, %Incoming{} = incoming, initial_context) do
    scope = %{
      provider: to_string(incoming.provider),
      channel_config_id: incoming.routing_context.channel_config_id,
      sender_id: incoming.author_id
    }

    with :ok <- IdentityResolver.authorize_channel_sender(person, scope),
         :ok <- validate_channel_input(incoming, initial_context) do
      Repo.transaction(fn ->
        prepare_channel_or_rollback(person, scope, incoming, initial_context)
      end)
    end
  end

  def prepare_channel_input(_person, _incoming, _context), do: {:error, :invalid_request}

  defp prepare_channel_or_rollback(person, scope, incoming, context) do
    case prepare_channel_conversation(person, scope, incoming, context) do
      {:ok, bound} -> bound
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp validate_channel_input(incoming, context) do
    if valid_channel_identity?(incoming) and
         valid_channel_content?(incoming.content) and
         (is_nil(context) or valid_channel_content?(context)) do
      :ok
    else
      {:error, :invalid_request}
    end
  end

  defp valid_channel_identity?(incoming) do
    expected = %{
      scoped?: true,
      channel_type: to_string(incoming.provider),
      channel_config_id: incoming.routing_context.channel_config_id,
      external_channel_id: incoming.channel_id,
      participant_id: incoming.author_id,
      external_thread_id: nil
    }

    identity = Map.take(conversation_identity(incoming), Map.keys(expected))

    identity == expected and is_nil(incoming.thread_id) and
      CommunicationPolicy.kind(incoming) == {:ok, :direct}
  end

  defp valid_channel_content?(content),
    do: is_binary(content) and String.trim(content) != "" and byte_size(content) <= 100_000

  defp prepare_channel_conversation(person, scope, incoming, context) do
    case incoming.routing_context.conversation_id do
      nil ->
        prepare_new_channel_conversation(person, incoming, context)

      id ->
        with {:ok, %{conversation: conversation}} <-
               restore_channel_conversation(person, scope, id, limit: 1) do
          {:ok, bind_channel_input(incoming, person, conversation)}
        end
    end
  end

  defp prepare_new_channel_conversation(person, incoming, context) do
    with {:ok, conversation, created?} <-
           resolve_scoped_conversation(incoming.author_id, conversation_identity(incoming)),
         {:ok, conversation} <- maybe_assign_person(conversation, person.id),
         true <- conversation.person_id == person.id,
         :ok <- seed_channel_context(conversation, person, incoming, if(created?, do: context)) do
      {:ok, bind_channel_input(incoming, person, conversation)}
    else
      false -> {:error, :conversation_not_found}
      error -> error
    end
  end

  defp bind_channel_input(incoming, person, conversation) do
    metadata =
      incoming.metadata
      |> Map.put(
        "conversation",
        Map.put(incoming.metadata["conversation"], "channel_id", conversation.external_channel_id)
      )
      |> Map.delete("conversation_id")
      |> Map.put(:conversation_id, conversation.id)

    %{
      incoming
      | channel_id: conversation.external_channel_id,
        person: IdentityResolver.person_payload(person),
        routing_context: %{incoming.routing_context | conversation_id: conversation.id},
        metadata: metadata
    }
  end

  defp seed_channel_context(_conversation, _person, _incoming, nil), do: :ok

  defp seed_channel_context(conversation, person, incoming, context) do
    with {:ok, message} <-
           add_message(conversation, %{
             role: "user",
             content: context,
             author_id: incoming.author_id,
             author_name: incoming.author_name,
             metadata: %{}
           }),
         {:ok, facts} <-
           Facts.for_capture(
             bind_channel_input(incoming, person, conversation),
             person.id,
             :direct
           ),
         {:ok, _} <-
           capture_canonical_message(
             facts,
             %{
               role: message.role,
               content: message.content,
               author_id: message.author_id,
               author_name: message.author_name,
               metadata: %{}
             },
             %{
               provider: facts.provider,
               channel_config_id: facts.channel_config_id,
               source_scope: incoming.routing_context.source_scope,
               provenance: "channel_adapter",
               existing_message_id: message.id
             }
           ) do
      :ok
    end
  end

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

  This prepares an execution binding, not execution authorization. `admitted?`
  reports whether a new input was prepared; the provisional record has no
  `admitted_at` until `admit_execution/3` authorizes it.

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
    with {:ok, conv} <- conversation_for_admission(msg, source),
         {:ok, conv} <- maybe_store_author_id(conv, msg.author_id),
         {:ok, conv} <- maybe_assign_person(conv, Incoming.person_id(msg)),
         {:ok, {user_message, admitted?, finalization_token}} <-
           get_or_insert_admitted_message(conv, msg, source),
         {:ok, execution} <-
           ExecutionLifecycle.admit(conv, user_message, finalization_token, source) do
      {:ok,
       %{
         conversation_id: conv.id,
         user_message_id: user_message.id,
         execution_id: execution && execution.id,
         admitted?: admitted?,
         finalization_token: finalization_token
       }}
    end
  end

  defp conversation_for_admission(msg, {:ok, provider, account_key}) do
    captured =
      Repo.get_by(Message,
        source_provider: provider,
        source_account_key: account_key,
        external_message_id: msg.message_id
      )

    person_id = Incoming.person_id(msg)
    recipient_admission_conversation(captured, msg, person_id)
  end

  defp conversation_for_admission(msg, _source), do: legacy_admission_conversation(msg)

  defp recipient_admission_conversation(%Message{conversation_id: nil} = captured, msg, person_id)
       when is_integer(person_id) and person_id > 0 do
    transcripts =
      Repo.all(
        from t in Transcript,
          join: p in TranscriptMessage,
          on: p.transcript_id == t.id,
          where:
            p.message_id == ^captured.id and t.owner_person_id == ^person_id and
              t.provider == ^captured.source_provider,
          limit: 2
      )

    case transcripts do
      [transcript] ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
          Jason.encode!(["history_execution:conversation", transcript.id, person_id])
        ])

        identity = %{
          scoped?: true,
          channel_type: transcript.provider,
          channel_config_id: transcript.channel_config_id,
          external_channel_id: transcript.external_channel_id,
          external_thread_id: transcript.external_thread_id
        }

        key = "history:#{transcript.id}:person:#{person_id}"
        conversation_for_persistence(msg, key, identity)

      [] ->
        legacy_admission_conversation(msg)

      _ ->
        {:error, :ambiguous_execution_scope}
    end
  end

  defp recipient_admission_conversation(
         %Message{role: "user", conversation_id: id},
         _msg,
         person_id
       )
       when is_binary(id) do
    # Preserve immutable canonical bindings on replay, including pre-cutover
    # containers. A new recipient's input must never inherit their ownership.
    case get_conversation(id) do
      %Conversation{person_id: ^person_id} = conversation -> {:ok, conversation}
      _ -> {:error, :unauthorized}
    end
  end

  defp recipient_admission_conversation(_captured, msg, _person_id),
    do: legacy_admission_conversation(msg)

  defp legacy_admission_conversation(msg) do
    identity = conversation_identity(msg)
    key = identity.conversation_key || identity.participant_id || msg.author_id
    conversation_for_persistence(msg, key, identity)
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

    attrs = %{
      conversation_id: conv.id,
      role: "user",
      content: msg.content || "",
      author_id: msg.author_id,
      metadata: metadata
    }

    %Message{}
    |> Message.admission_changeset(attrs, %{
      person_id: Incoming.person_id(msg),
      provider_sent_at: msg.routing_context.provider_sent_at
    })
    |> insert_message(conv)
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
        execution_id = Keyword.get(opts, :execution_id)

        with {:ok, _execution} <- ExecutionLifecycle.fetch(user_message, execution_id),
             true <- valid_finalization_token?(user_message, finalization_token, execution_id),
             :ok <-
               ExecutionLifecycle.authorize_finalization(
                 user_message,
                 Keyword.get(opts, :actor),
                 execution_id
               ) do
          finalize_locked_message(user_message, result, artifacts, opts)
        else
          false -> Repo.rollback(:invalid_finalization_token)
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp finalization_token_hash(token),
    do: token |> then(&:crypto.hash(:sha256, &1)) |> Base.encode64()

  defp valid_finalization_token?(user_message, token, execution_id) do
    case ExecutionLifecycle.fetch(user_message, execution_id) do
      {:ok, nil} ->
        Map.get(user_message.metadata || %{}, "finalization_token_hash") ==
          finalization_token_hash(token)

      {:ok, execution} ->
        execution.finalization_token_hash == finalization_token_hash(token)

      _ ->
        false
    end
  end

  defp lock_admitted_message(user_message_id) do
    Repo.one(
      from m in Message,
        where: m.id == ^user_message_id and m.role == "user",
        lock: "FOR UPDATE"
    )
  end

  defp finalize_locked_message(%Message{} = user_message, result, artifacts, opts) do
    {:ok, execution} = ExecutionLifecycle.fetch(user_message, opts[:execution_id])

    status =
      if execution,
        do: execution.status,
        else: Map.get(user_message.metadata || %{}, "execution_status")

    case status do
      status when status in ["completed", "failed"] ->
        finalized_result(user_message, execution)

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
           |> private_answer_attrs(user_message)
           |> update_in(
             [:metadata],
             &Map.put(&1 || %{}, "in_reply_to_message_id", user_message.id)
           ),
         {:ok, assistant_message} <-
           Repo.insert(
             message_changeset(%Conversation{id: user_message.conversation_id}, assistant_attrs)
           ),
         {:ok, _artifacts} <-
           insert_trace_artifacts(Repo, assistant_message, artifacts, artifact_max_bytes(opts)),
         {:ok, _execution} <-
           persist_private_execution(
             user_message,
             assistant_message.id,
             "completed",
             result,
             artifacts,
             opts[:execution_id]
           ) do
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
           insert_trace_artifacts(Repo, user_message, artifacts, artifact_max_bytes(opts)),
         {:ok, _execution} <-
           persist_private_execution(
             user_message,
             nil,
             "failed",
             result,
             artifacts,
             opts[:execution_id]
           ) do
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

    {metadata, trace} =
      if ExecutionLifecycle.private?(user_message),
        do: {metadata, []},
        else: {Map.put(metadata, "execution", execution_metadata(result)), trace}

    user_message
    |> Message.changeset(%{metadata: metadata, trace: trace})
    |> Repo.update()
  end

  defp private_answer_attrs(attrs, input) do
    if ExecutionLifecycle.private?(input) do
      attrs
      |> Map.merge(%{trace: [], prompt_tokens: nil, completion_tokens: nil, total_tokens: nil})
      |> Map.update!(:metadata, &Map.drop(&1, ["measurements"]))
    else
      attrs
    end
  end

  defp persist_private_execution(input, answer_id, status, result, artifacts, execution_id) do
    usage =
      ~w(model prompt_tokens completion_tokens total_tokens)a
      |> Enum.reduce(%{}, fn key, usage ->
        case map_get(result, Atom.to_string(key)) do
          nil -> usage
          value -> Map.put(usage, Atom.to_string(key), value)
        end
      end)

    ExecutionLifecycle.finish(
      input,
      answer_id,
      status,
      assistant_trace(result, artifacts),
      usage,
      private_execution_metadata(result),
      execution_id
    )
  end

  defp private_execution_metadata(result) do
    outcome = execution_metadata(result)

    case map_get(result, "measurements") do
      measurements when is_map(measurements) ->
        Map.put(outcome, "measurements", Measurements.metadata_measurements(measurements))

      _ ->
        outcome
    end
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

  defp finalized_result(user_message, execution) when not is_nil(execution) do
    %{
      conversation_id: user_message.conversation_id,
      user_message_id: user_message.id,
      assistant_message_id: execution.public_answer_message_id
    }
  end

  defp finalized_result(user_message, nil) do
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
    with {:ok, conversation, _created?} <- resolve_scoped_conversation(channel_user_id, identity),
         do: {:ok, conversation}
  end

  defp get_or_create_conversation_for_identity(channel_user_id, identity) do
    get_or_create_conversation_for_channel(channel_user_id, identity.channel_type, nil)
  end

  defp resolve_scoped_conversation(channel_user_id, identity) do
    result =
      Repo.transaction(fn ->
        key =
          Jason.encode!([
            "conversation",
            identity.channel_type,
            identity.channel_config_id,
            identity.external_channel_id,
            identity.external_thread_id,
            channel_user_id
          ])

        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])

        case find_or_create_scoped_conversation(channel_user_id, identity) do
          {:ok, conversation, created?} -> {conversation, created?}
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {conversation, created?}} -> {:ok, conversation, created?}
      error -> error
    end
  end

  defp find_or_create_scoped_conversation(channel_user_id, identity) do
    query = communication_scope_query(channel_user_id, identity)

    case Repo.one(query) do
      %Conversation{} = conversation ->
        {:ok, conversation, false}

      nil ->
        attrs = %{
          channel_user_id: channel_user_id,
          channel_type: identity.channel_type,
          channel_config_id: identity.channel_config_id,
          external_channel_id: identity.external_channel_id,
          external_thread_id: identity.external_thread_id
        }

        create_scoped_conversation(attrs, query)
    end
  end

  defp create_scoped_conversation(attrs, query) do
    case create_conversation(attrs) do
      {:ok, conversation} ->
        {:ok, conversation, true}

      {:error, %Ecto.Changeset{} = changeset} ->
        with {:ok, conversation} <- recover_scope_conflict(changeset, query),
             do: {:ok, conversation, false}
    end
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
    %{"attachments" => Enum.map(attachments, &Zaq.Contracts.Record.attachment_metadata/1)}
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
    unresolved =
      Enum.filter(conversations, &(is_nil(&1.person_id) and not is_nil(&1.channel_config_id)))

    if unresolved == [], do: conversations, else: do_backfill(conversations, unresolved)
  end

  defp do_backfill(conversations, unresolved) do
    by_channel_user_id =
      unresolved |> Enum.map(& &1.channel_user_id) |> Enum.reject(&is_nil/1)

    by_author_id =
      unresolved |> Enum.map(&Map.get(&1.metadata, "author_id")) |> Enum.reject(&is_nil/1)

    lookup_ids = Enum.uniq(by_channel_user_id ++ by_author_id)
    config_ids = Enum.uniq(Enum.map(unresolved, & &1.channel_config_id))

    channel_map =
      if lookup_ids == [] do
        %{}
      else
        Repo.all(
          from c in PersonChannel,
            where: c.channel_identifier in ^lookup_ids and c.channel_config_id in ^config_ids,
            select: {{c.channel_config_id, c.channel_identifier}, c.person_id}
        )
        |> Map.new()
      end

    # Build a map of id → resolved person_id for conversations that need updating
    updates =
      Map.new(
        for conv <- unresolved,
            resolved =
              Map.get(channel_map, {conv.channel_config_id, conv.channel_user_id}) ||
                Map.get(
                  channel_map,
                  {conv.channel_config_id, Map.get(conv.metadata, "author_id")}
                ),
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
    conversation
    |> message_changeset(attrs)
    |> insert_message(conversation)
  end

  defp insert_message(changeset, conversation) do
    with {:ok, msg} <- Repo.insert(changeset) do
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
    |> MessageAuthor.project()
  end

  @doc """
  Loads bounded legacy agent history for an internally validated runtime binding.
  Conversation reads exclude incomplete inputs; Person/channel reads retain their
  legacy cross-conversation scope. This is not a public authorization boundary.
  """
  def list_agent_history(%{conversation_id: id}) when is_binary(id) and id != "" do
    from(m in Message,
      where:
        m.conversation_id == ^id and
          fragment("COALESCE(?->>'execution_status', 'completed') = 'completed'", m.metadata),
      order_by: [desc: m.inserted_at],
      limit: 500,
      select:
        struct(m, [
          :id,
          :role,
          :content,
          :metadata,
          :history_context,
          :provider_sent_at,
          :inserted_at,
          :attachments
        ])
    )
    |> Repo.all()
    |> MessageAuthor.project()
  end

  def list_agent_history(%{person_id: id, channel_type: type})
      when is_integer(id) and is_binary(type) do
    conversations =
      from(c in Conversation, where: c.person_id == ^id and c.channel_type == ^type, select: c.id)

    from(m in Message,
      where: m.conversation_id in subquery(conversations),
      order_by: [desc: m.inserted_at],
      limit: 500,
      select:
        struct(m, [
          :id,
          :role,
          :content,
          :metadata,
          :history_context,
          :provider_sent_at,
          :inserted_at,
          :attachments
        ])
    )
    |> Repo.all()
    |> MessageAuthor.project()
  end

  def list_agent_history(_binding), do: []

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

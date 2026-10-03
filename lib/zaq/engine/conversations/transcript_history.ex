defmodule Zaq.Engine.Conversations.TranscriptHistory do
  @moduledoc """
  Engine-local canonical transcript storage. Internal Channels/Engine callers
  supply already-verified provider and connector context; this is not an agent
  Action or a grant to assert an arbitrary recipient. Message content is stored
  once, placements are serialized per transcript, and readers only receive a
  Person-authorized content projection (never private execution data).
  """

  import Ecto.Query

  alias Zaq.Accounts.Person
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Conversations.{Conversation, Message, Transcript, TranscriptMessage}
  alias Zaq.Engine.History.{Facts, Strategy}
  alias Zaq.Engine.Messages.SourceIdentity
  alias Zaq.Permissions
  alias Zaq.Permissions.ChannelHistoryResource
  alias Zaq.Repo

  @message_fields [
    :role,
    :content,
    :external_message_id,
    :author_id,
    :author_name,
    :history_context,
    :provider_sent_at,
    :attachments
  ]
  @max_page_size 100

  @doc "Atomically resolves strategy scopes and appends one provider message to each target."
  @spec capture(Facts.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def capture(%Facts{} = facts, attrs, source)
      when is_map(attrs) and is_map(source) do
    Repo.transaction(fn -> capture_locked(facts, attrs, source) end)
  end

  def capture(_, _, _), do: {:error, :invalid_request}

  @doc "Prepares canonical content and fixed targets without making the message visible."
  def prepare_capture(%Facts{} = facts, attrs, source) do
    Repo.transaction(fn -> capture_locked(facts, attrs, source, :prepare) end)
  end

  defp capture_locked(facts, attrs, source, mode \\ :append) do
    root_facts = %{facts | thread_id: nil, parent: nil}

    with {:ok, root_facts} <- Facts.new(Map.from_struct(root_facts)),
         :ok <- valid_capture_source?(root_facts, source),
         :ok <- valid_capture_people?(root_facts),
         :ok <-
           lock_source_identity(root_facts.provider, root_facts.channel_config_id, source, attrs),
         {:ok, attrs, source} <- reuse_scoped_legacy_message(root_facts, facts, attrs, source),
         {:ok, root_targets} <- Strategy.association_targets(root_facts),
         {:ok, root_targets} <-
           consistent_replicated_audience?(root_facts, root_targets, attrs, source),
         {:ok, targets} <- capture_targets(facts, root_facts, root_targets) do
      placements = Enum.map(targets, &capture_target!(&1, root_facts, attrs, source, mode))
      actor = Enum.find(placements, fn {owner, _} -> owner == root_facts.actor_person_id end)
      {_, first} = actor || hd(placements)

      %{
        message_id: first.message_id,
        transcript_id: first.transcript_id,
        position: first.position,
        transcript_ids:
          Map.new(placements, fn {owner, placement} -> {owner, placement.transcript_id} end)
      }
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp valid_capture_source?(facts, source) do
    if source[:provider] == facts.provider and
         source[:channel_config_id] == facts.channel_config_id and
         is_binary(source[:provenance]) and source[:provenance] != "" and
         SourceIdentity.valid_scope?(source[:source_scope]) and
         (facts.kind != :replicated or
            (is_binary(source[:source_scope]) and source[:source_scope] != "")),
       do: :ok,
       else: {:error, :invalid_history_source}
  end

  defp valid_capture_people?(facts) do
    ids =
      facts.recipient_person_ids
      |> Enum.concat([facts.actor_person_id])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    existing =
      Repo.all(
        from p in Person,
          where: p.id in ^ids,
          order_by: p.id,
          lock: "FOR KEY SHARE",
          select: p.id
      )

    if length(existing) == length(ids),
      do: :ok,
      else: {:error, :invalid_history_person}
  end

  @doc false
  def lock_source_identity(provider, config_id, source, attrs) do
    case Map.get(attrs, :external_message_id) do
      external_id when is_binary(external_id) and external_id != "" ->
        account_key =
          SourceIdentity.account_key(
            provider,
            config_id,
            source[:source_scope]
          )

        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
          Jason.encode!([provider, account_key, external_id])
        ])

        :ok

      _ ->
        :ok
    end
  end

  defp reuse_scoped_legacy_message(_root, _facts, attrs, %{existing_message_id: id} = source)
       when is_binary(id),
       do: {:ok, attrs, source}

  defp reuse_scoped_legacy_message(root, facts, attrs, source) do
    case Map.get(attrs, :external_message_id) do
      id when is_binary(id) and id != "" ->
        find_legacy_source(root, facts, attrs, source, id)

      _ ->
        {:ok, attrs, source}
    end
  end

  defp find_legacy_source(root, facts, attrs, source, external_id) do
    query =
      from message in Message,
        join: conversation in Conversation,
        on: conversation.id == message.conversation_id,
        where:
          message.role == "user" and is_nil(message.source_provider) and
            fragment("?->>'external_message_id' = ?", message.metadata, ^external_id) and
            conversation.channel_type == ^root.provider,
        limit: 2,
        select: {message, conversation}

    query = legacy_source_scope(query, root, facts, source)

    case Repo.all(query) do
      [] ->
        {:ok, attrs, source}

      [{message, _conversation}] ->
        if matching_legacy_user_message?(message, attrs),
          do:
            {:ok, Map.put(attrs, :role, "user"),
             Map.put(source, :existing_message_id, message.id)},
          else: {:error, :source_conflict}

      _ ->
        {:error, :source_conflict}
    end
  end

  defp matching_legacy_user_message?(message, attrs) do
    attrs[:role] in ["external", "user"] and message.content == attrs[:content] and
      message.author_id == attrs[:author_id]
  end

  defp legacy_source_scope(query, root, %{thread_id: thread_id} = facts, source) do
    case Facts.strategy(facts) do
      {:ok, :replicated} ->
        expected = %{
          "provider" => root.provider,
          "channel_config_id" => root.channel_config_id,
          "channel_id" => root.conversation_id || root.channel_id,
          "source_scope" => source[:source_scope]
        }

        where(
          query,
          [message, _],
          fragment("?->'history_source' = ?::jsonb", message.metadata, ^Jason.encode!(expected))
        )

      {:ok, strategy} ->
        query =
          where(
            query,
            [_, conversation],
            conversation.channel_config_id == ^root.channel_config_id and
              conversation.external_channel_id == ^root.channel_id
          )

        if strategy == :shared,
          do: scope_legacy_thread(query, thread_id),
          else: query
    end
  end

  defp scope_legacy_thread(query, nil),
    do: where(query, [_, conversation], is_nil(conversation.external_thread_id))

  defp scope_legacy_thread(query, thread_id),
    do: where(query, [_, conversation], conversation.external_thread_id == ^thread_id)

  defp consistent_replicated_audience?(
         facts,
         [%{strategy: "replicated"} | _] = targets,
         attrs,
         source
       ) do
    case Map.get(attrs, :external_message_id) do
      external_id when is_binary(external_id) and external_id != "" ->
        account_key =
          SourceIdentity.account_key(
            facts.provider,
            facts.channel_config_id,
            source[:source_scope]
          )

        check_existing_audience(facts, account_key, external_id, targets)

      _ ->
        {:ok, targets}
    end
  end

  defp consistent_replicated_audience?(_facts, targets, _attrs, _source),
    do: {:ok, targets}

  defp check_existing_audience(facts, account_key, external_id, targets) do
    case Repo.get_by(Message,
           source_provider: facts.provider,
           source_account_key: account_key,
           external_message_id: external_id
         ) do
      nil ->
        {:ok, targets}

      %Message{id: message_id} ->
        existing =
          Repo.all(
            from placement in TranscriptMessage,
              join: transcript in Transcript,
              on: transcript.id == placement.transcript_id,
              where: placement.message_id == ^message_id and transcript.strategy == "replicated",
              order_by: transcript.id,
              select: transcript
          )

        existing_owners = existing |> Enum.map(& &1.owner_person_id) |> Enum.uniq() |> Enum.sort()
        requested_owners = targets |> Enum.map(& &1.owner_person_id) |> Enum.uniq() |> Enum.sort()

        if existing_owners == requested_owners,
          do: {:ok, Enum.map(existing, &transcript_target/1)},
          else: {:error, :source_conflict}
    end
  end

  defp transcript_target(transcript) do
    Map.take(transcript, [
      :strategy,
      :provider,
      :channel_config_id,
      :external_channel_id,
      :external_thread_id,
      :parent_id,
      :owner_person_id,
      :permission_resource_type,
      :permission_resource_id,
      :scope_key
    ])
  end

  defp capture_targets(%Facts{thread_id: nil}, root_facts, root_targets),
    do: {:ok, Enum.map(root_targets, &target_for_actor(&1, root_facts.actor_person_id))}

  defp capture_targets(%Facts{} = facts, root_facts, root_targets) do
    case Facts.strategy(root_facts) do
      {:ok, :replicated} ->
        {:ok, Enum.map(root_targets, &target_for_actor(&1, root_facts.actor_person_id))}

      {:ok, _} ->
        with [root_target] <- root_targets,
             {:ok, parent, created?} <- ensure_transcript(root_target),
             :ok <- seed_history_grants(root_facts, parent, created?),
             {:ok, threaded} <- Facts.new(Map.from_struct(%{facts | parent: parent})),
             {:ok, [target]} <- Strategy.association_targets(threaded) do
          {:ok, [{threaded.actor_person_id, target}]}
        else
          _ -> {:error, :invalid_history_scope}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp target_for_actor(target, actor_id), do: {target.owner_person_id || actor_id, target}

  defp capture_target!({owner, target}, facts, attrs, source, mode) do
    with {:ok, transcript, created?} <- ensure_transcript(target),
         :ok <- seed_history_grants(facts, transcript, created?),
         {:ok, placement} <-
           prepare_or_append(
             transcript,
             attrs,
             Map.put(source, :recipient_person_id, owner),
             mode
           ) do
      {owner, placement}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp prepare_or_append(transcript, attrs, source, :append),
    do: append(transcript.id, attrs, source)

  defp prepare_or_append(transcript, attrs, source, :prepare) do
    with :ok <- valid_scope?(transcript, source, :write),
         {:ok, message} <- canonical_message(transcript, attrs, source) do
      {:ok, %{message_id: message.id, transcript_id: transcript.id, position: nil}}
    end
  end

  @doc "Prepares the fixed Direct/Shared targets of a verified execution response."
  def prepare_execution_response(input_id, %Message{} = response, delivery) do
    input = Repo.get(Message, input_id)

    if match?(%Message{}, input) and matching_execution_pair?(input, response) do
      ids =
        Repo.all(
          from p in TranscriptMessage,
            join: t in Transcript,
            on: t.id == p.transcript_id,
            where:
              p.message_id == ^input_id and t.strategy in ["direct", "shared"] and
                t.provider == ^delivery.provider and
                t.channel_config_id == ^delivery.channel_config_id and
                t.external_channel_id == ^delivery.channel_id,
            order_by: t.id,
            select: t.id
        )

      with false <- ids == [],
           :ok <- bind_response_source(response, delivery) do
        {:ok, %{message_id: response.id, transcript_ids: ids}}
      else
        true -> {:error, :unavailable_history_input}
        {:error, _} = error -> error
      end
    else
      {:error, :invalid_execution_response}
    end
  end

  # Runs inside HistoryIngress's locked confirmation transaction. Bind the
  # existing answer rather than minting a second message or relying on metadata.
  defp bind_response_source(response, delivery) do
    scope = delivery[:source_scope]
    id = delivery[:message_id]

    if SourceIdentity.valid_scope?(scope) and is_binary(id) and id != "" do
      attrs = %{
        source_provider: delivery.provider,
        source_account_key:
          SourceIdentity.account_key(delivery.provider, delivery.channel_config_id, scope),
        external_message_id: id
      }

      case response |> Message.canonical_changeset(attrs) |> Repo.update() do
        {:ok, _} -> :ok
        {:error, _} -> {:error, :source_conflict}
      end
    else
      {:error, :invalid_history_source}
    end
  end

  @doc "Associates a confirmed canonical message with its durable, fixed target references."
  def associate_prepared(%Message{} = message, ids) when is_list(ids) and ids != [] do
    Repo.transaction(fn ->
      Enum.each(Enum.sort(ids), &associate_prepared_target!(&1, message))
    end)
  end

  defp associate_prepared_target!(id, message) do
    receipt = message.metadata["delivery_confirmation"]

    with %Transcript{} = transcript <-
           Repo.one(from t in Transcript, where: t.id == ^id, lock: "FOR UPDATE"),
         :ok <- valid_scope?(transcript, %{}, :read),
         true <-
           transcript.provider == receipt["provider"] and
             transcript.channel_config_id == receipt["channel_config_id"] and
             transcript.external_channel_id == confirmed_scope(transcript, receipt),
         {:ok, _} <- attach(transcript, message, %{provenance: "provider_confirmed"}) do
      :ok
    else
      _ -> Repo.rollback(:source_scope_mismatch)
    end
  end

  defp ensure_transcript(%{strategy: "replicated"} = target) do
    case existing_replicated_transcript(target) do
      %Transcript{} = transcript -> {:ok, transcript, false}
      nil -> insert_transcript(target)
    end
  end

  defp ensure_transcript(target), do: insert_transcript(target)

  defp insert_transcript(target) do
    with {:ok, candidate} <-
           Repo.insert(Transcript.changeset(%Transcript{}, target),
             on_conflict: :nothing
           ),
         %Transcript{} = transcript <-
           Repo.get_by(Transcript,
             provider: target.provider,
             channel_config_id: target.channel_config_id,
             scope_key: target.scope_key
           ),
         true <- matching_transcript_target?(transcript, target) do
      {:ok, transcript, candidate.id == transcript.id}
    else
      false -> {:error, :source_scope_mismatch}
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # A Person merge intentionally leaves each historical replica's permission
  # resource and scope key intact. Prefer the survivor's canonical scope when it
  # exists; otherwise continue the oldest transferred replica instead of minting
  # an empty replacement.
  defp existing_replicated_transcript(target) do
    query =
      from t in Transcript,
        where:
          t.strategy == "replicated" and t.provider == ^target.provider and
            t.channel_config_id == ^target.channel_config_id and
            t.external_channel_id == ^target.external_channel_id and
            t.owner_person_id == ^target.owner_person_id,
        order_by: [
          asc: fragment("CASE WHEN ? = ? THEN 0 ELSE 1 END", t.scope_key, ^target.scope_key),
          asc: t.inserted_at,
          asc: t.id
        ],
        limit: 1

    query =
      if is_nil(target.external_thread_id),
        do: where(query, [t], is_nil(t.external_thread_id)),
        else: where(query, [t], t.external_thread_id == ^target.external_thread_id)

    Repo.one(query)
  end

  defp confirmed_scope(%{strategy: "replicated"}, receipt),
    do: receipt["conversation_id"] || receipt["channel_id"]

  defp confirmed_scope(_, receipt), do: receipt["channel_id"]

  defp matching_transcript_target?(transcript, target) do
    keys = [
      :strategy,
      :provider,
      :channel_config_id,
      :external_channel_id,
      :external_thread_id,
      :parent_id,
      :owner_person_id,
      :permission_resource_type,
      :permission_resource_id
    ]

    Map.take(transcript, keys) == Map.take(target, keys)
  end

  defp seed_history_grants(%Facts{kind: :direct} = facts, %{parent_id: nil} = transcript, true) do
    resource = {transcript.permission_resource_type, transcript.permission_resource_id}

    facts.recipient_person_ids
    |> Enum.concat([facts.actor_person_id])
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn person_id, _ ->
      case Permissions.grant(resource, %{
             person_id: person_id,
             source_key: "channel_history:participant",
             access_rights: ["read"]
           }) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp seed_history_grants(%Facts{kind: :replicated}, transcript, true) do
    resource = {transcript.permission_resource_type, transcript.permission_resource_id}

    case Permissions.grant(resource, %{
           person_id: transcript.owner_person_id,
           source_key: "channel_history:recipient",
           access_rights: ["read"]
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp seed_history_grants(_facts, _transcript, _created?), do: :ok

  defp matching_execution_pair?(input, response) do
    input.role == "user" and response.role == "assistant" and
      not is_nil(input.conversation_id) and input.conversation_id == response.conversation_id and
      Map.get(response.metadata || %{}, "in_reply_to_message_id") == input.id
  end

  @doc "Atomically inserts/reuses one canonical message and attaches it at a committed position."
  @spec append(term(), map(), map()) :: {:ok, map()} | {:error, term()}
  def append(transcript_id, message_attrs, source_context)
      when is_map(message_attrs) and is_map(source_context) do
    case Ecto.UUID.cast(transcript_id) do
      {:ok, id} -> Repo.transaction(fn -> append_locked(id, message_attrs, source_context) end)
      :error -> {:error, :not_found}
    end
  end

  def append(_transcript_id, _message_attrs, _source_context), do: {:error, :invalid_request}

  defp append_locked(id, attrs, context) do
    case Repo.one(from t in Transcript, where: t.id == ^id, lock: "FOR UPDATE") do
      %Transcript{} = transcript -> append_to_transcript(transcript, attrs, context)
      nil -> Repo.rollback(:not_found)
    end
  end

  defp append_to_transcript(transcript, attrs, context) do
    with :ok <- valid_scope?(transcript, context, :write),
         {:ok, message} <- canonical_message(transcript, attrs, context),
         {:ok, association} <- attach(transcript, message, context) do
      %{message_id: message.id, transcript_id: transcript.id, position: association.position}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc "Returns only the bounded, authorized transcript content after a local position."
  @spec list(Person.t() | nil, term(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(%Person{id: person_id} = person, transcript_id, opts)
      when is_integer(person_id) and person_id > 0 and is_list(opts) do
    with {:ok, id} <- Ecto.UUID.cast(transcript_id),
         :ok <- persisted_person?(person_id),
         %Transcript{} = transcript <- Repo.get(Transcript, id),
         :ok <- fresh_history?(transcript),
         :ok <- valid_scope?(transcript, %{}, :read),
         {:access, true} <-
           {:access,
            Permissions.can?(
              person,
              :read,
              {transcript.permission_resource_type, transcript.permission_resource_id}
            )},
         {:ok, cursor, upper, limit} <- page_options(opts) do
      {:ok, projected_messages(id, cursor, upper, limit)}
    else
      :error -> {:error, :not_found}
      nil -> {:error, :not_found}
      {:access, false} -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  def list(_person, _transcript_id, _opts), do: {:error, :unauthorized}

  defp fresh_history?(%Transcript{strategy: "legacy"}), do: {:error, :unauthorized}
  defp fresh_history?(_), do: :ok

  @doc "Internal BO administration projection; caller must verify a current super-admin user."
  def list_admin(transcript_id, opts \\ [])

  def list_admin(transcript_id, opts) when is_list(opts) do
    with {:ok, id} <- Ecto.UUID.cast(transcript_id),
         %Transcript{} = transcript <- Repo.get(Transcript, id),
         :ok <- valid_admin_scope?(transcript),
         {:ok, cursor, upper, limit} <- page_options(opts) do
      {:ok, projected_messages(id, cursor, upper, limit)}
    else
      _ -> {:error, :not_found}
    end
  end

  def list_admin(_, _), do: {:error, :not_found}

  defp valid_admin_scope?(%Transcript{strategy: "legacy"} = transcript) do
    conversation_id = transcript.conversation_id

    if is_binary(conversation_id) and transcript.provider == "legacy" and
         is_nil(transcript.channel_config_id) and is_nil(transcript.owner_person_id) and
         is_nil(transcript.parent_id) and
         transcript.scope_key == "legacy:#{conversation_id}" and
         {transcript.permission_resource_type, transcript.permission_resource_id} ==
           {"legacy_conversation", conversation_id} and
         Repo.exists?(from c in Conversation, where: c.id == ^conversation_id),
       do: :ok,
       else: {:error, :not_found}
  end

  defp valid_admin_scope?(transcript), do: valid_scope?(transcript, %{}, :read)

  defp projected_messages(id, cursor, upper, limit) do
    query =
      from placement in TranscriptMessage,
        join: message in Message,
        on: placement.message_id == message.id,
        where: placement.transcript_id == ^id and placement.position > ^cursor,
        order_by: [asc: placement.position],
        limit: ^limit,
        select: %{
          message_id: message.id,
          position: placement.position,
          role: message.role,
          content: message.content,
          author_id: message.author_id,
          author_name: message.author_name,
          provider_sent_at: message.provider_sent_at,
          attachments: message.attachments
        }

    query = if upper, do: where(query, [p], p.position <= ^upper), else: query
    query |> Repo.all() |> Enum.map(&sanitize_attachments/1)
  end

  defp persisted_person?(person_id) do
    if Repo.get(Person, person_id), do: :ok, else: {:error, :unauthorized}
  end

  defp valid_scope?(%Transcript{} = transcript, context, mode) do
    with :ok <- valid_connector_scope(transcript, mode),
         true <- mode != :write or matching_source?(transcript, context),
         true <- matching_resource?(transcript),
         true <- matching_parent?(transcript) do
      :ok
    else
      _ -> {:error, :source_scope_mismatch}
    end
  end

  defp valid_connector_scope(%Transcript{} = transcript, mode) do
    config_id = transcript.channel_config_id
    config = if is_integer(config_id) and config_id > 0, do: Repo.get(ChannelConfig, config_id)

    case config do
      %ChannelConfig{kind: "retrieval", provider: provider, archived_at: archived_at} = config
      when provider == transcript.provider ->
        if mode == :write and (not is_nil(archived_at) or not config.enabled),
          do: {:error, :source_scope_mismatch},
          else: :ok

      _ ->
        {:error, :source_scope_mismatch}
    end
  end

  defp matching_source?(transcript, context) do
    context[:provider] == transcript.provider and
      context[:channel_config_id] == transcript.channel_config_id and
      is_binary(context[:provenance]) and context[:provenance] != "" and
      valid_source_scope?(context[:source_scope]) and
      (transcript.strategy != "replicated" or
         context[:recipient_person_id] == transcript.owner_person_id)
  end

  defp valid_source_scope?(nil), do: true

  defp valid_source_scope?(scope) when is_binary(scope),
    do: scope != "" and byte_size(scope) <= 160

  defp valid_source_scope?(_scope), do: false

  defp matching_resource?(%Transcript{strategy: strategy} = transcript)
       when strategy in ["direct", "shared"] do
    channel_id = transcript.external_channel_id

    is_binary(channel_id) and channel_id != "" and is_nil(transcript.owner_person_id) and
      {transcript.permission_resource_type, transcript.permission_resource_id} ==
        ChannelHistoryResource.for(transcript.provider, transcript.channel_config_id, channel_id)
  end

  defp matching_resource?(%Transcript{strategy: "replicated"} = transcript),
    do:
      is_integer(transcript.owner_person_id) and transcript.owner_person_id > 0 and
        transcript.permission_resource_type == "person_history" and
        is_binary(transcript.permission_resource_id) and transcript.permission_resource_id != ""

  defp matching_resource?(_transcript), do: false

  @parent_scope_fields [
    :strategy,
    :provider,
    :channel_config_id,
    :external_channel_id,
    :owner_person_id,
    :permission_resource_type,
    :permission_resource_id
  ]

  defp matching_parent?(%Transcript{parent_id: nil}), do: true

  defp matching_parent?(%Transcript{} = transcript) do
    case Repo.get(Transcript, transcript.parent_id) do
      %Transcript{} = parent ->
        parent.parent_id == nil and
          Map.take(parent, @parent_scope_fields) == Map.take(transcript, @parent_scope_fields)

      _ ->
        false
    end
  end

  defp canonical_message(transcript, attrs, context) do
    attrs =
      attrs
      |> Map.take(@message_fields)
      |> Map.update(:attachments, [], &sanitize_attachment_list/1)

    external_id = Map.get(attrs, :external_message_id)

    account_key =
      SourceIdentity.account_key(
        transcript.provider,
        transcript.channel_config_id,
        context[:source_scope]
      )

    attrs =
      if is_nil(external_id) do
        attrs
      else
        Map.merge(attrs, %{source_provider: transcript.provider, source_account_key: account_key})
      end

    changeset = Message.canonical_changeset(%Message{}, attrs)

    if changeset.valid? do
      case context[:existing_message_id] do
        nil -> insert_or_reuse_message(changeset, transcript, account_key, external_id)
        existing_id -> reuse_admitted_message(existing_id, changeset, transcript, context)
      end
    else
      {:error, changeset}
    end
  end

  defp reuse_admitted_message(id, changeset, transcript, context) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Message{} = existing <-
           Repo.one(from m in Message, where: m.id == ^uuid, lock: "FOR UPDATE"),
         true <-
           matches_admitted_source?(existing, changeset, transcript, context) or
             matches_confirmed_response?(existing, changeset, transcript, context),
         {:ok, message} <-
           existing
           |> Message.canonical_changeset(
             changeset
             |> Ecto.Changeset.apply_changes()
             |> Map.take(@message_fields ++ [:source_provider, :source_account_key])
           )
           |> Repo.update() do
      {:ok, message}
    else
      _ -> {:error, :source_conflict}
    end
  end

  defp matches_admitted_source?(message, changeset, transcript, context) do
    candidate = Ecto.Changeset.apply_changes(changeset)
    conversation = Repo.get(Conversation, message.conversation_id)

    admitted_content_matches?(message, candidate) and
      admitted_source_fields_match?(message, candidate) and
      conversation_matches_transcript?(conversation, transcript, message, context)
  end

  defp matches_confirmed_response?(message, changeset, transcript, context) do
    candidate = Ecto.Changeset.apply_changes(changeset)
    conversation = Repo.get(Conversation, message.conversation_id)
    input_id = Map.get(message.metadata || %{}, "in_reply_to_message_id")
    input = if is_binary(input_id), do: Repo.get(Message, input_id)

    confirmed_response_content?(message, candidate, transcript, context) and
      match?(%Conversation{}, conversation) and conversation.channel_type == transcript.provider and
      confirmed_response_input?(message, conversation, input, transcript)
  end

  defp confirmed_response_content?(message, candidate, transcript, context) do
    context[:provenance] == "provider_confirmed" and transcript.strategy == "replicated" and
      confirmed_response_message?(message, candidate)
  end

  defp confirmed_response_message?(message, candidate) do
    message.role == "assistant" and candidate.role == "assistant" and
      message.content == candidate.content and
      (is_nil(message.author_id) or message.author_id == candidate.author_id) and
      is_binary(candidate.external_message_id) and
      admitted_source_fields_match?(message, candidate)
  end

  defp confirmed_response_input?(message, conversation, input, transcript) do
    match?(%Message{role: "user"}, input) and
      input.conversation_id == message.conversation_id and
      confirmed_input_scope?(input, transcript) and
      confirmed_conversation?(conversation, input, transcript)
  end

  defp confirmed_conversation?(%Conversation{channel_config_id: nil}, input, transcript) do
    source = if match?(%Message{}, input), do: input.metadata["history_source"]

    is_map(source) and source["provider"] == transcript.provider and
      source["channel_config_id"] == transcript.channel_config_id and
      source["channel_id"] == transcript.external_channel_id
  end

  defp confirmed_conversation?(%Conversation{channel_config_id: id}, _input, transcript),
    do: id == transcript.channel_config_id

  defp confirmed_input_scope?(input, %{external_thread_id: nil} = transcript),
    do: input.author_id == transcript.external_channel_id

  defp confirmed_input_scope?(input, transcript) do
    Repo.exists?(
      from p in TranscriptMessage,
        join: t in Transcript,
        on: t.id == p.transcript_id,
        where:
          p.message_id == ^input.id and t.strategy == "replicated" and
            t.channel_config_id == ^transcript.channel_config_id and
            t.provider == ^transcript.provider and
            t.external_channel_id == ^transcript.external_channel_id
    )
  end

  defp admitted_content_matches?(message, candidate) do
    message.role == "user" and candidate.role == "user" and
      is_binary(message.author_id) and message.author_id != "" and
      message.author_id == candidate.author_id and
      message.content == candidate.content and
      is_map(message.metadata) and
      Map.get(message.metadata, "external_message_id") == candidate.external_message_id
  end

  defp admitted_source_fields_match?(message, candidate) do
    Enum.all?(
      [:source_provider, :source_account_key, :external_message_id],
      fn field ->
        existing = Map.get(message, field)
        is_nil(existing) or existing == Map.get(candidate, field)
      end
    )
  end

  defp conversation_matches_transcript?(
         %Conversation{channel_config_id: nil} = conversation,
         transcript,
         message,
         context
       ) do
    conversation.channel_type == transcript.provider and
      message.metadata["history_source"] == %{
        "provider" => transcript.provider,
        "channel_config_id" => transcript.channel_config_id,
        "channel_id" => transcript.external_channel_id,
        "source_scope" => context[:source_scope]
      }
  end

  defp conversation_matches_transcript?(
         %Conversation{} = conversation,
         transcript,
         _message,
         _context
       ) do
    conversation.channel_type == transcript.provider and
      conversation.channel_config_id == transcript.channel_config_id and
      conversation.external_channel_id == transcript.external_channel_id
  end

  defp conversation_matches_transcript?(_, _transcript, _message, _context), do: false

  defp insert_or_reuse_message(changeset, _transcript, _account_key, nil),
    do: Repo.insert(changeset)

  defp insert_or_reuse_message(changeset, transcript, account_key, external_id) do
    source_conflict =
      {:unsafe_fragment,
       "(source_provider, source_account_key, external_message_id) " <>
         "WHERE external_message_id IS NOT NULL"}

    with {:ok, _} <-
           Repo.insert(changeset, on_conflict: :nothing, conflict_target: source_conflict),
         %Message{} = message <-
           Repo.get_by(Message,
             source_provider: transcript.provider,
             source_account_key: account_key,
             external_message_id: external_id
           ) do
      candidate = Ecto.Changeset.apply_changes(changeset)

      if same_message?(message, candidate) and same_placement_scope?(message, transcript),
        do: {:ok, message},
        else: {:error, :source_conflict}
    else
      nil -> {:error, :source_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp same_message?(message, attrs) do
    (message.role == attrs.role or
       (message.role == "user" and attrs.role == "external" and
          not is_nil(message.conversation_id))) and
      message.content == attrs.content and
      message.author_id == attrs.author_id and
      (message.attachments || []) == (attrs.attachments || [])
  end

  defp same_placement_scope?(message, transcript) do
    existing =
      Repo.all(
        from placement in TranscriptMessage,
          join: placed in Transcript,
          on: placed.id == placement.transcript_id,
          where: placement.message_id == ^message.id,
          select: placed
      )

    Enum.all?(existing, fn placed ->
      placed.strategy == transcript.strategy and
        placed.external_channel_id == transcript.external_channel_id and
        (placed.external_thread_id == transcript.external_thread_id or
           (placed.strategy in ["direct", "shared"] and
              (placed.id == transcript.parent_id or placed.parent_id == transcript.id)))
    end)
  end

  defp attach(transcript, message, context) do
    case Repo.get_by(TranscriptMessage, transcript_id: transcript.id, message_id: message.id) do
      %TranscriptMessage{} = existing ->
        {:ok, existing}

      nil ->
        position = transcript.next_position + 1

        with {:ok, association} <-
               %TranscriptMessage{}
               |> TranscriptMessage.changeset(%{
                 transcript_id: transcript.id,
                 message_id: message.id,
                 position: position,
                 provenance: context[:provenance]
               })
               |> Repo.insert(),
             {:ok, _} <-
               transcript |> Ecto.Changeset.change(next_position: position) |> Repo.update() do
          {:ok, association}
        end
    end
  end

  defp page_options(opts) do
    cursor = Keyword.get(opts, :after_position, 0)
    upper = Keyword.get(opts, :up_to_position)
    limit = Keyword.get(opts, :limit, 50)

    if is_integer(cursor) and cursor >= 0 and
         (is_nil(upper) or (is_integer(upper) and upper >= cursor)) and
         is_integer(limit) and limit > 0 and limit <= @max_page_size do
      {:ok, cursor, upper, limit}
    else
      {:error, :invalid_cursor}
    end
  end

  defp sanitize_attachments(%{attachments: attachments} = message) do
    %{message | attachments: sanitize_attachment_list(attachments)}
  end

  defp sanitize_attachment_list(attachments) when is_list(attachments) do
    attachments
    |> Enum.map(&sanitize_descriptor/1)
    |> Enum.reject(&(&1 == %{}))
  end

  defp sanitize_attachment_list(_attachments), do: []

  defp sanitize_descriptor(descriptor) when is_map(descriptor) do
    strings =
      Enum.reduce([{"id", 255}, {"name", 512}, {"mime_type", 255}], %{}, fn {key, max}, acc ->
        case Map.get(descriptor, key) do
          value when is_binary(value) and byte_size(value) <= max -> Map.put(acc, key, value)
          _ -> acc
        end
      end)

    case Map.get(descriptor, "size") do
      size when is_integer(size) and size >= 0 -> Map.put(strings, "size", size)
      _ -> strings
    end
  end

  defp sanitize_descriptor(_descriptor), do: %{}
end

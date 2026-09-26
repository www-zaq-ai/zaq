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
  alias Zaq.Engine.Conversations.{Message, Transcript, TranscriptMessage}
  alias Zaq.Permissions.ChannelHistoryResource
  alias Zaq.Repo

  @message_fields [
    :role,
    :content,
    :external_message_id,
    :author_id,
    :author_name,
    :provider_sent_at,
    :attachments
  ]
  @max_page_size 100

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
         :ok <- valid_scope?(transcript, %{}, :read),
         :ok <- authorized?(person, transcript),
         {:ok, cursor, upper, limit} <- page_options(opts) do
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
      {:ok, query |> Repo.all() |> Enum.map(&sanitize_attachments/1)}
    else
      :error -> {:error, :not_found}
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def list(_person, _transcript_id, _opts), do: {:error, :unauthorized}

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
      %ChannelConfig{kind: "retrieval", provider: provider, archived_at: archived_at}
      when provider == transcript.provider ->
        if mode == :write and not is_nil(archived_at),
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

  defp authorized?(%Person{} = person, %Transcript{strategy: strategy} = transcript)
       when strategy in ["direct", "shared"] do
    resource = {transcript.permission_resource_type, transcript.permission_resource_id}
    if ChannelHistoryResource.can_read?(person, resource), do: :ok, else: {:error, :unauthorized}
  end

  defp authorized?(%Person{id: id}, %Transcript{strategy: "replicated", owner_person_id: id}),
    do: :ok

  defp authorized?(_person, _transcript), do: {:error, :unauthorized}

  defp canonical_message(transcript, attrs, context) do
    attrs =
      attrs
      |> Map.take(@message_fields)
      |> Map.update(:attachments, [], &sanitize_attachment_list/1)

    external_id = Map.get(attrs, :external_message_id)

    account_key =
      Jason.encode!([transcript.provider, transcript.channel_config_id, context[:source_scope]])

    attrs =
      if is_nil(external_id) do
        attrs
      else
        Map.merge(attrs, %{source_provider: transcript.provider, source_account_key: account_key})
      end

    changeset = Message.canonical_changeset(%Message{}, attrs)

    if changeset.valid? do
      insert_or_reuse_message(changeset, transcript, account_key, external_id)
    else
      {:error, changeset}
    end
  end

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
      if same_message?(message, candidate), do: {:ok, message}, else: {:error, :source_conflict}
    else
      nil -> {:error, :source_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp same_message?(message, attrs) do
    message.role == attrs.role and message.content == attrs.content and
      message.author_id == attrs.author_id and
      (message.attachments || []) == (attrs.attachments || [])
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

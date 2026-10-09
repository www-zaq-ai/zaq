defmodule Zaq.Engine.ChannelConversations do
  @moduledoc """
  Authorized private-chat readiness and restoration for trusted channel integrations.

  The configured adapter verifies external senders before calling this internal
  boundary. Readiness resolves a connector-scoped Person but never creates a chat.
  Actual messages use ordinary Engine admission and canonical history capture.
  Restoration requires both literal conversation ownership and canonical grants;
  generic conversation reads and legacy transcripts are not fallback paths.
  """

  import Ecto.Query

  alias Zaq.Accounts.{People, Person}
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.{Conversation, Transcript}
  alias Zaq.Engine.History.{CommunicationPolicy, Facts}
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.People.IdentityResolver
  alias Zaq.Repo

  @doc "Dispatches the closed internal readiness/history operations."
  def dispatch(%{operation: :initialize} = request) do
    initialize(request, Map.get(request, :conversation_id))
  end

  def dispatch(%{operation: :history, conversation_id: id} = request) do
    history(request, id, Map.get(request, :page, []))
  end

  def dispatch(%{operation: :prepare, incoming: %Incoming{} = incoming} = request) do
    prepare(request, incoming, Map.get(request, :prompt_context))
  end

  def dispatch(_request), do: {:error, :invalid_request}

  @doc "Validates a channel sender and optionally resumes an authorized chat without creating one."
  def initialize(scope, conversation_id \\ nil) do
    with {:ok, config, person} <- resolve_sender(scope) do
      case conversation_id do
        nil -> {:ok, %{conversation_id: nil, created: false}}
        id -> resume(config, person, id)
      end
    end
  end

  @doc "Restores bounded, Person-authorized canonical content for one privately owned chat."
  def history(scope, conversation_id, opts \\ []) do
    with {:ok, config, person} <- resolve_sender(scope),
         {:ok, transcript} <- bound_transcript(config, person, conversation_id) do
      read_history(person, transcript, opts)
    end
  end

  @doc """
  Binds a received question to a private chat before ordinary Engine admission.

  The channel supplies a scoped canonical Incoming, including its server-resolved
  native chat reference. Optional initial content uses ordinary add_message/2 and
  canonical capture only for a new chat. It is not an execution or a new message
  type; title generation retains the ordinary user-message behavior.
  """
  def prepare(scope, incoming, prompt_context \\ nil)

  def prepare(scope, %Incoming{} = incoming, prompt_context) do
    with {:ok, config, person} <- resolve_sender(scope),
         :ok <- validate_incoming(incoming, scope, config),
         :ok <- validate_seed(prompt_context) do
      Repo.transaction(fn -> prepare_or_rollback(config, person, incoming, prompt_context) end)
    end
  end

  def prepare(_scope, _incoming, _prompt_context), do: {:error, :invalid_request}

  defp prepare_or_rollback(config, person, incoming, prompt_context) do
    case prepare_chat(config, person, incoming, prompt_context) do
      {:ok, prepared} -> prepared
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp validate_incoming(incoming, scope, config) do
    if valid_question?(incoming, scope.sender_id) and valid_identity?(incoming, config) do
      :ok
    else
      {:error, :invalid_request}
    end
  end

  defp valid_question?(incoming, sender) do
    incoming.author_id == sender and is_nil(incoming.thread_id) and
      is_binary(incoming.channel_id) and incoming.channel_id != "" and
      is_binary(incoming.content) and String.trim(incoming.content) != "" and
      byte_size(incoming.content) <= 100_000
  end

  defp valid_identity?(incoming, config) do
    expected = %{
      "scoped" => true,
      "channel_type" => config.provider,
      "channel_config_id" => config.id,
      "channel_id" => incoming.channel_id,
      "participant_id" => incoming.author_id,
      "thread_id" => nil
    }

    identity = Map.get(incoming.metadata || %{}, "conversation")

    is_map(identity) and Map.take(identity, Map.keys(expected)) == expected and
      to_string(incoming.provider) == config.provider and
      incoming.routing_context.channel_config_id == config.id and
      CommunicationPolicy.kind(incoming) == {:ok, :direct}
  end

  defp validate_seed(nil), do: :ok

  defp validate_seed(content) when is_binary(content) do
    if String.trim(content) != "" and byte_size(content) <= 100_000,
      do: :ok,
      else: {:error, :invalid_request}
  end

  defp validate_seed(_content), do: {:error, :invalid_request}

  defp prepare_chat(config, person, incoming, context) do
    case incoming.routing_context.conversation_id do
      nil ->
        with {:ok, conversation} <-
               Conversations.create_conversation(%{
                 channel_type: config.provider,
                 channel_config_id: config.id,
                 external_channel_id: incoming.channel_id,
                 channel_user_id: incoming.author_id,
                 person_id: person.id
               }),
             :ok <- seed_message(conversation, person, incoming, context) do
          {:ok, bind_incoming(incoming, person, conversation.id)}
        end

      id ->
        with {:ok, transcript} <- bound_transcript(config, person, id),
             {:ok, _} <- read_history(person, transcript, limit: 1),
             %Conversation{external_channel_id: channel} <- Conversations.get_conversation(id) do
          identity = Map.put(incoming.metadata["conversation"], "channel_id", channel)

          incoming = %{
            incoming
            | channel_id: channel,
              metadata: Map.put(incoming.metadata, "conversation", identity)
          }

          {:ok, bind_incoming(incoming, person, id)}
        end
    end
  end

  defp bind_incoming(incoming, person, id) do
    %{
      incoming
      | person: IdentityResolver.person_payload(person),
        routing_context: %{incoming.routing_context | conversation_id: id},
        metadata:
          incoming.metadata |> Map.delete("conversation_id") |> Map.put(:conversation_id, id)
    }
  end

  defp seed_message(_conversation, _person, _incoming, nil), do: :ok

  defp seed_message(conversation, person, incoming, content) do
    attrs = %{
      role: "user",
      content: content,
      author_id: incoming.author_id,
      author_name: incoming.author_name,
      metadata: %{}
    }

    with {:ok, message} <- Conversations.add_message(conversation, attrs),
         {:ok, facts} <-
           Facts.for_capture(%{
             provider: to_string(incoming.provider),
             channel_config_id: conversation.channel_config_id,
             channel_id: conversation.external_channel_id,
             conversation_id: conversation.id,
             kind: :direct,
             actor_person_id: person.id
           }),
         {:ok, _capture} <-
           Conversations.capture_canonical_message(facts, attrs, %{
             provider: facts.provider,
             channel_config_id: facts.channel_config_id,
             source_scope: incoming.routing_context.source_scope,
             provenance: "channel_adapter",
             existing_message_id: message.id
           }) do
      :ok
    end
  end

  defp resolve_sender(%{channel_config_id: id, sender_id: sender} = scope)
       when is_integer(id) and id > 0 and is_binary(sender) do
    with true <- String.trim(sender) != "",
         %ChannelConfig{kind: "retrieval", enabled: true, archived_at: nil} = config <-
           Repo.get(ChannelConfig, id),
         true <- config.provider == Map.get(scope, :provider, config.provider),
         {:ok, %Person{status: "active"} = person} <-
           People.find_or_create_from_channel(config.provider, %{
             "channel_id" => sender,
             "channel_config_id" => config.id
           }) do
      {:ok, config, person}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp resolve_sender(_scope), do: {:error, :unauthorized}

  defp resume(config, person, id) do
    with {:ok, transcript} <- bound_transcript(config, person, id),
         {:ok, _messages} <- read_history(person, transcript, limit: 1) do
      {:ok, %{conversation_id: id, created: false}}
    end
  end

  defp bound_transcript(config, person, id) do
    with true <- is_binary(id),
         {:ok, id} <- Ecto.UUID.cast(id),
         %Conversation{
           person_id: person_id,
           channel_config_id: config_id,
           channel_type: provider,
           external_channel_id: channel,
           external_thread_id: nil,
           status: "active"
         } <- Conversations.get_conversation(id),
         true <- person_id == person.id and config_id == config.id and provider == config.provider,
         true <- is_binary(channel) and channel != "",
         %Transcript{} = transcript <-
           Repo.one(
             from t in Transcript,
               where:
                 t.provider == ^provider and t.channel_config_id == ^config_id and
                   t.external_channel_id == ^channel and is_nil(t.external_thread_id) and
                   t.strategy == "direct"
           ) do
      {:ok, transcript}
    else
      _ -> {:error, :conversation_not_found}
    end
  end

  defp read_history(person, transcript, opts) when is_list(opts) do
    case Conversations.list_canonical_messages(person, transcript.id, opts) do
      {:error, :unauthorized} -> {:error, :conversation_not_found}
      {:error, :not_found} -> {:error, :conversation_not_found}
      result -> result
    end
  end

  defp read_history(_person, _transcript, _opts), do: {:error, :invalid_cursor}
end

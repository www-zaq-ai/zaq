defmodule Zaq.Engine.HistoryIngress do
  @moduledoc """
  Persists normalized communication facts supplied by internal Channels events.

  Channels validates and normalizes transport facts without selecting policy.
  Engine selects the history strategy and validates connector,
  Person, execution and placement scope; a struct or metadata map alone never
  authenticates an external caller. Capture and admission share the same source
  namespace supplied in the incoming routing context.
  """

  import Ecto.Query

  alias Zaq.Accounts.People
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.ChannelHistoryMembership
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.{Message, TranscriptHistory}
  alias Zaq.Engine.History.{CommunicationPolicy, Facts}
  alias Zaq.Engine.HistoryDeliveryWorker
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Engine.Messages.Incoming.Audience
  alias Zaq.Engine.Messages.SourceIdentity
  alias Zaq.People.IdentityResolver
  alias Zaq.People.Resolver
  alias Zaq.Repo

  @doc "Captures a verified channel message with a connector-scoped Person author."
  def capture(incoming, opts \\ [])

  def capture(%Incoming{} = incoming, opts) when is_list(opts) do
    resolver = Keyword.get(opts, :identity_resolver, IdentityResolver)

    with {:ok, kind} <- history_kind(incoming),
         {:ok, person} <- resolver.resolve(incoming, Keyword.get(opts, :identity_opts, [])) do
      capture_resolved(incoming, person.id, kind, resolver)
    end
  end

  def capture(_, _), do: {:error, :invalid_request}

  @doc "Checks exact provider/connector/source coordinates against durable outbound confirmation."
  @spec confirmed_delivery?(map()) :: {:ok, boolean()} | {:error, atom()}
  def confirmed_delivery?(
        %{
          provider: provider,
          channel_config_id: config_id,
          source_scope: scope,
          message_id: message_id
        } = reference
      )
      when is_binary(provider) and is_integer(config_id) and config_id > 0 and
             is_binary(scope) and scope != "" and is_binary(message_id) and message_id != "" do
    with :ok <-
           active_confirmation_scope(%{"provider" => provider, "channel_config_id" => config_id}) do
      reference = Map.take(reference, [:provider, :channel_config_id, :source_scope, :message_id])

      confirmed? =
        case confirmed_message(reference) do
          %Message{
            role: "assistant",
            metadata: %{
              "delivery_confirmation" => %{
                "provider" => ^provider,
                "channel_config_id" => ^config_id,
                "message_id" => ^message_id
              }
            }
          } ->
            true

          _ ->
            false
        end

      {:ok, confirmed?}
    end
  end

  def confirmed_delivery?(_), do: {:error, :invalid_delivery_scope}

  @doc "Captures an author already resolved at the Engine routing boundary."
  def capture_resolved(incoming, person_id, kind, resolver \\ IdentityResolver)

  def capture_resolved(%Incoming{} = incoming, person_id, kind, resolver)
      when is_integer(person_id) and person_id > 0 do
    with {:ok, ^kind} <- history_kind(incoming),
         {:ok, recipients} <- recipients(incoming, kind, resolver),
         {:ok, facts} <-
           Facts.for_capture(%{
             provider: to_string(incoming.provider),
             channel_config_id: incoming.routing_context.channel_config_id,
             channel_id: incoming.channel_id,
             conversation_id: incoming.routing_context.conversation_id,
             kind: kind,
             actor_person_id: person_id,
             recipient_person_ids: recipients,
             thread_id: incoming.thread_id
           }) do
      capture =
        Conversations.capture_canonical_message(
          facts,
          %{
            role: "external",
            content: incoming.content,
            external_message_id: incoming.message_id,
            author_id: incoming.author_id,
            author_name: incoming.author_name,
            history_context: history_context(incoming, person_id),
            provider_sent_at: incoming.routing_context.provider_sent_at,
            attachments: Enum.map(incoming.attachments, &attachment_descriptor/1)
          },
          %{
            provider: facts.provider,
            channel_config_id: facts.channel_config_id,
            provenance: "channel_adapter",
            source_scope: incoming.routing_context.source_scope
          }
        )

      observe_sender(capture, incoming, person_id, kind)
      capture
    end
  end

  def capture_resolved(_, _, _, _), do: {:error, :invalid_request}

  defp observe_sender(
         {:ok, %{transcript_id: id}},
         %Incoming{
           author_id: member,
           routing_context: %{sender_membership: %{member_id: member} = evidence}
         },
         person_id,
         :channel
       ) do
    # Access reconciliation is independent of factual capture. Denied or failed
    # presence evidence must never erase a legitimate provider message.
    ChannelHistoryMembership.observe_sender(id, person_id, evidence)
  end

  defp observe_sender(_, _, _, _), do: :ok

  defp history_context(incoming, person_id) do
    context = incoming.routing_context

    participants =
      case context.audience do
        %Audience{participants: [_ | _] = participants} ->
          participants

        _ ->
          [%{identifier: incoming.author_id, role: :sender, display_name: incoming.author_name}]
      end

    resolved =
      Enum.flat_map(participants, fn participant ->
        case People.match_by_channel(
               context.identity_platform || to_string(incoming.provider),
               participant.identifier,
               context.channel_config_id
             ) do
          {:ok, person} -> [%{"person_id" => person.id, "role" => to_string(participant.role)}]
          _ -> []
        end
      end)

    %{
      "identity_platform" => context.identity_platform || to_string(incoming.provider),
      "author_person_id" => person_id,
      "participants" => Enum.uniq([%{"person_id" => person_id, "role" => "sender"} | resolved]),
      "title_style" =>
        if(CommunicationPolicy.title_style(incoming),
          do: to_string(CommunicationPolicy.title_style(incoming))
        ),
      "subject" => context.display_subject
    }
  end

  @doc "Durably records confirmed delivery before attempting its idempotent history association."
  def capture_confirmed(%{confirmation: :confirmed} = delivery) do
    with {:ok, id} <- record_confirmation(delivery) do
      associate_confirmation(id)
    end
  end

  def capture_confirmed(_), do: {:error, :unconfirmed_delivery}

  @doc "Retries only the association of a previously confirmed canonical message."
  def associate_confirmation(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Message{
           metadata: %{
             "history_association" => %{"transcript_ids" => ids},
             "delivery_confirmation" => receipt
           }
         } = message <- Repo.get(Message, uuid),
         :ok <- active_confirmation_scope(receipt) do
      TranscriptHistory.associate_prepared(message, ids)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :missing_confirmation}
    end
  end

  defp active_confirmation_scope(%{"provider" => provider, "channel_config_id" => id}) do
    case Repo.get(ChannelConfig, id) do
      %ChannelConfig{provider: ^provider, enabled: true, archived_at: nil, kind: "retrieval"} ->
        :ok

      _ ->
        {:error, :invalid_delivery_scope}
    end
  end

  @doc "Commits confirmed canonical content, fixed targets and its ID-only recovery job together."
  def record_confirmation(
        %{confirmation: :confirmed, provider: provider, channel_config_id: id, kind: kind} =
          delivery
      )
      when is_binary(provider) and is_integer(id) and id > 0 and
             kind in [:direct, :channel, :replicated],
      do: record_confirmation_transaction(delivery)

  def record_confirmation(%{confirmation: :confirmed}), do: {:error, :invalid_delivery_scope}

  def record_confirmation(_), do: {:error, :unconfirmed_delivery}

  defp record_confirmation_transaction(delivery) do
    Repo.transaction(fn ->
      # Serialize the same delivery before looking up its canonical message.
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        Jason.encode!([
          delivery[:provider],
          delivery[:channel_config_id],
          delivery[:source_scope],
          delivery[:assistant_message_id] || delivery[:message_id]
        ])
      ])

      TranscriptHistory.lock_source_identity(
        delivery[:provider],
        delivery[:channel_config_id],
        %{source_scope: delivery[:source_scope]},
        %{external_message_id: delivery[:message_id]}
      )

      fingerprint = confirmation_fingerprint(delivery)
      message = confirmed_message(delivery)

      id =
        case message do
          %Message{metadata: %{"history_association" => %{"fingerprint" => ^fingerprint}}} ->
            message.id

          %Message{metadata: %{"history_association" => _}} ->
            Repo.rollback(:conflicting_delivery_confirmation)

          _ ->
            prepare_confirmation(delivery, fingerprint, message)
        end

      case HistoryDeliveryWorker.enqueue(id) do
        {:ok, _} -> id
        _ -> Repo.rollback(:history_capture_unavailable)
      end
    end)
  end

  defp confirmation_fingerprint(delivery) do
    [
      :provider,
      :channel_config_id,
      :channel_id,
      :conversation_id,
      :kind,
      :source_scope,
      :message_id,
      :user_message_id,
      :assistant_message_id
    ]
    |> Map.new(&{&1, delivery[&1]})
    |> Map.put(:content_digest, content_digest(delivery[:content]))
    |> Map.put(
      :audience,
      case Audience.normalize(delivery[:audience]) do
        nil -> nil
        audience -> Map.from_struct(audience)
      end
    )
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode64()
  end

  defp content_digest(content) when is_binary(content),
    do: :crypto.hash(:sha256, content) |> Base.encode64()

  defp content_digest(_), do: nil

  defp confirmed_message(%{assistant_message_id: id}) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.one(from m in Message, where: m.id == ^uuid, lock: "FOR UPDATE")
      _ -> nil
    end
  end

  defp confirmed_message(
         %{provider: provider, channel_config_id: config, message_id: id} = delivery
       )
       when is_binary(id) do
    key = SourceIdentity.account_key(provider, config, delivery[:source_scope])

    Repo.one(
      from m in Message,
        where:
          m.source_provider == ^provider and
            m.source_account_key == ^key and m.external_message_id == ^id,
        lock: "FOR UPDATE"
    )
  end

  defp confirmed_message(_), do: nil

  defp prepare_confirmation(delivery, fingerprint, locked_message) do
    with %ChannelConfig{enabled: true, archived_at: nil, provider: provider, kind: "retrieval"} <-
           Repo.get(ChannelConfig, delivery[:channel_config_id]),
         true <- provider == delivery[:provider],
         {:ok, prepared} <- prepare_delivery(delivery, locked_message) do
      message =
        Map.get_lazy(prepared, :message, fn -> Repo.get!(Message, prepared.message_id) end)

      ids =
        if is_map(prepared.transcript_ids),
          do: Map.values(prepared.transcript_ids),
          else: prepared.transcript_ids

      receipt =
        Map.new(
          [:provider, :channel_config_id, :channel_id, :conversation_id, :message_id],
          &{Atom.to_string(&1), delivery[&1]}
        )

      case message.metadata["delivery_confirmation"] do
        nil -> :ok
        ^receipt -> :ok
        _ -> Repo.rollback(:conflicting_delivery_confirmation)
      end

      metadata =
        message.metadata
        |> Map.put("delivery_confirmation", receipt)
        |> Map.put("history_association", %{
          "fingerprint" => fingerprint,
          "transcript_ids" => Enum.sort(ids)
        })

      message |> Message.confirmation_changeset(metadata) |> Repo.update!()
      message.id
    else
      {:error, reason} -> Repo.rollback(reason)
      _ -> Repo.rollback(:invalid_delivery_scope)
    end
  end

  defp prepare_delivery(
         %{kind: kind, user_message_id: input_id, assistant_message_id: response_id} = delivery,
         %Message{} = response
       )
       when kind in [:direct, :channel] and is_binary(input_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(response_id),
         true <- response.id == uuid do
      TranscriptHistory.prepare_execution_response(input_id, response, delivery)
    else
      _ -> {:error, :invalid_delivery_scope}
    end
  end

  defp prepare_delivery(
         %{
           kind: :replicated,
           audience: audience,
           channel_id: channel_id,
           message_id: message_id,
           content: content,
           source_scope: scope
         } = delivery,
         _locked_message
       ) do
    with %Audience{} = audience <- Audience.normalize(audience),
         true <- channel_id in audience.recipients,
         true <- is_binary(scope) and scope != "",
         {:ok, facts} <- delivery_facts(delivery, audience) do
      TranscriptHistory.prepare_capture(
        facts,
        %{
          role: "assistant",
          content: content,
          external_message_id: message_id,
          author_id: audience.sender
        },
        %{
          provider: delivery.provider,
          channel_config_id: delivery.channel_config_id,
          provenance: "provider_confirmed",
          source_scope: scope,
          existing_message_id: Map.get(delivery, :assistant_message_id)
        }
      )
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_recipient_evidence}
    end
  end

  defp prepare_delivery(_, _), do: {:error, :invalid_delivery_scope}

  defp delivery_facts(delivery, audience) do
    recipients =
      audience.recipients
      |> Enum.map(&discovered_recipient(delivery.channel_config_id, audience.platform, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if recipients == [] do
      {:error, :no_linked_recipient}
    else
      Facts.new(
        Map.merge(
          Map.take(delivery, [:provider, :channel_config_id, :channel_id, :conversation_id, :kind]),
          %{
            # A confirmed assistant's sender is transport provenance, not a
            # recipient Person. Only the actual delivery audience owns copies.
            actor_person_id: nil,
            recipient_person_ids: recipients
          }
        )
      )
    end
  end

  defp discovered_recipient(config_id, platform, identifier) do
    attrs = Resolver.normalize(platform, %{channel_id: identifier})

    case People.find_or_create_from_channel(
           platform,
           Map.put(attrs, "channel_config_id", config_id)
         ) do
      {:ok, %{id: id, status: "active"}} -> id
      {:ok, _inactive} -> nil
      {:error, _reason} -> Repo.rollback(:unresolved_history_recipient)
    end
  end

  defp history_kind(incoming), do: CommunicationPolicy.kind(incoming)

  defp recipients(incoming, :replicated, resolver),
    do: resolver.resolve_audience(incoming, incoming.routing_context.channel_config_id)

  defp recipients(_incoming, _kind, _resolver), do: {:ok, []}

  defp attachment_descriptor(record) do
    Enum.reduce([:id, :name, :mime_type, :size], %{}, fn key, acc ->
      case Map.get(record, key) do
        nil -> acc
        value -> Map.put(acc, Atom.to_string(key), value)
      end
    end)
  end
end

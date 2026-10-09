defmodule Zaq.Engine.ScopedChannelRatingTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  alias Jido.Chat.ReactionEvent
  alias Zaq.Accounts.People
  alias Zaq.Channels.{CommunicationBridge, JidoChatBridge}
  alias Zaq.Engine.{Api, ChannelHistoryAdmin, Conversations, HistoryIngress}
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Conversations.Message
  alias Zaq.Engine.History.Delivery, as: HistoryDelivery
  alias Zaq.Engine.History.Facts
  alias Zaq.Engine.Messages.{Incoming, Outgoing, SourceIdentity}
  alias Zaq.Event
  alias Zaq.Permissions
  alias Zaq.Permissions.ChannelHistoryResource

  defmodule Router do
    alias Zaq.Engine.Api
    def dispatch(event), do: Api.handle_event(event, event.opts[:action], nil)
  end

  defmodule NumericTelegramAdapter do
    def send_message(_channel_id, _text, _opts), do: {:ok, %{external_message_id: 9_001}}
  end

  setup do
    old = Application.get_env(:zaq, :chat_bridge_node_router_module)
    channels = Application.fetch_env!(:zaq, :channels)

    Application.put_env(
      :zaq,
      :channels,
      put_in(channels, [:telegram, :adapter], NumericTelegramAdapter)
    )

    Application.put_env(:zaq, :chat_bridge_node_router_module, Router)

    on_exit(fn ->
      if old,
        do: Application.put_env(:zaq, :chat_bridge_node_router_module, old),
        else: Application.delete_env(:zaq, :chat_bridge_node_router_module)

      Application.put_env(:zaq, :channels, channels)
    end)

    :ok
  end

  test "finalized and confirmed responses retain their UUID and can be rated in direct, shared and threaded history" do
    for provider <- bridge_providers(),
        {kind, thread} <- [{:direct, nil}, {:channel, nil}, {:channel, "root"}] do
      config =
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: "Confirmed #{provider} #{kind} #{thread}",
          provider: provider,
          kind: "retrieval",
          url: "https://example.invalid",
          token: "token"
        })
        |> Repo.insert!()

      {:ok, person} =
        People.find_or_create_from_channel(provider, %{
          channel_id: "rater",
          channel_config_id: config.id,
          display_name: "Rater"
        })

      scope = if provider == "telegram", do: "room"

      incoming =
        Incoming.new(%{
          content: "hello",
          channel_id: "room",
          author_id: "rater",
          message_id: "root",
          provider: provider,
          routing_context: %{
            channel_config_id: config.id,
            conversation_type: if(kind == :direct, do: :one_to_one, else: :room),
            source_scope: scope
          }
        })

      assert {:ok, _} = HistoryIngress.capture(incoming)

      incoming =
        if thread, do: %{incoming | thread_id: thread, message_id: "thread-input"}, else: incoming

      incoming = CommunicationBridge.put_conversation_identity(incoming)
      assert {:ok, captured} = HistoryIngress.capture(incoming)

      resource = ChannelHistoryResource.for(provider, config.id, "room")

      for grant <- Permissions.list_direct(resource),
          do: assert(:ok = Permissions.revoke(resource, grant))

      assert Permissions.list_direct(resource) == []

      assert {:ok, binding} = Conversations.admit_incoming(incoming)
      result = %{answer: "Confirmed answer", error: false, trace: [%{"private" => "preserved"}]}

      assert {:ok, %{assistant_message_id: response_id}} =
               Conversations.finalize_incoming(
                 binding.user_message_id,
                 binding.finalization_token,
                 result
               )

      original = Repo.get!(Message, response_id)
      assert original.external_message_id == nil

      outgoing =
        Outgoing.from_pipeline_result(
          incoming,
          Map.merge(result, %{
            user_message_id: binding.user_message_id,
            assistant_message_id: response_id
          })
        )

      # Chat receipts carry the provider ID; unlike SMTP they do not supply a
      # separate history namespace. The native chat scope is on Outgoing.
      external_id = if provider == "telegram", do: "9001", else: "confirmed-answer"

      receipt =
        if provider == "telegram" do
          assert {:ok, %{confirmation: :confirmed, message_id: "9001"} = receipt} =
                   JidoChatBridge.do_send_reply(outgoing, %{
                     url: "https://example.invalid",
                     token: "token"
                   })

          receipt
        else
          %{confirmation: :confirmed, message_id: external_id}
        end

      message_count = Repo.aggregate(Message, :count)
      # A provider identity already owned by the input cannot be stolen by the
      # answer; the failed confirmation must leave the answer completely unbound.
      assert {:ok, %{history_capture: :unavailable, history_capture_error: :source_conflict}} =
               HistoryDelivery.capture(
                 {:ok, %{receipt | message_id: incoming.message_id}},
                 outgoing
               )

      assert Repo.get!(Message, response_id).external_message_id == nil
      assert Repo.get!(Message, response_id).metadata["delivery_confirmation"] == nil

      assert {:ok, %{history_capture: :stored}} =
               HistoryDelivery.capture({:ok, receipt}, outgoing)

      reaction =
        ReactionEvent.new(%{
          message_id: external_id,
          channel_id: "room",
          emoji: if(provider == "mattermost", do: "+1_medium_skin_tone", else: "👍"),
          user: %{user_id: "rater", user_name: "Rater"}
        })

      assert :ok = JidoChatBridge.handle_reaction_event(config, reaction)
      stored = Repo.get!(Message, response_id)

      assert %{message_id: ^response_id, rating: 5} =
               Conversations.get_rating(stored, %{person_id: person.id})

      assert Permissions.list_direct(resource) == []

      assert {:error, :unauthorized} =
               Conversations.list_canonical_messages(person, captured.transcript_id)

      assert stored.source_provider == provider
      assert stored.source_account_key == SourceIdentity.account_key(provider, config.id, scope)
      assert stored.external_message_id == external_id
      assert stored.trace == original.trace
      assert stored.conversation_id == original.conversation_id

      assert {:ok, %{history_capture: :stored}} =
               HistoryDelivery.capture({:ok, receipt}, outgoing)

      assert {:ok, :ok} = HistoryIngress.associate_confirmation(response_id)

      assert {:ok, detail} =
               ChannelHistoryAdmin.dispatch(%{op: :detail, id: captured.transcript_id})

      display = Enum.find(detail.messages, &(&1.message_id == response_id))
      assert display.rating_summary == %{positive: 1, negative: 0}

      assert {:ok,
              %{
                history_capture: :unavailable,
                history_capture_error: :conflicting_delivery_confirmation
              }} =
               HistoryDelivery.capture({:ok, %{receipt | message_id: "conflict"}}, outgoing)

      assert Repo.get!(Message, response_id).external_message_id == external_id
      assert Repo.aggregate(Message, :count) == message_count
    end
  end

  test "shared bridge rates canonical-only messages across providers without touching legacy matches" do
    for provider <- bridge_providers() do
      config =
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: provider,
          provider: provider,
          kind: "retrieval",
          url: "https://example.invalid",
          token: "token"
        })
        |> Repo.insert!()

      {:ok, person} = People.create_person(%{full_name: "Rater #{provider}"})

      {:ok, _} =
        People.add_channel(%{
          person_id: person.id,
          platform: provider,
          channel_identifier: "rater",
          channel_config_id: config.id
        })

      {:ok, facts} =
        Facts.new(%{
          provider: provider,
          channel_config_id: config.id,
          channel_id: "room",
          kind: :channel,
          actor_person_id: person.id
        })

      scope = if provider == "telegram", do: "room"

      {:ok, captured} =
        Conversations.capture_canonical_message(
          facts,
          %{role: "external", content: "Captured without execution", external_message_id: "post"},
          %{
            provider: provider,
            channel_config_id: config.id,
            provenance: "channel_adapter",
            source_scope: scope
          }
        )

      {:ok, legacy} =
        Conversations.create_conversation(%{channel_type: provider, channel_id: "old"})

      {:ok, old} =
        Conversations.add_message(legacy, %{
          role: "assistant",
          content: "old",
          metadata: %{"external_message_id" => "post"}
        })

      reaction =
        ReactionEvent.new(%{
          message_id: "post",
          channel_id: "room",
          emoji: "👍",
          user: %{user_id: "rater", user_name: "Rater"},
          added: true
        })

      assert :ok = JidoChatBridge.handle_reaction_event(config, reaction)
      message = Repo.get!(Message, captured.message_id)
      rating = Conversations.get_rating(message, %{person_id: person.id})
      assert rating
      assert rating.message_id == captured.message_id
      assert rating.person_id == person.id
      assert rating.channel_user_id == nil
      assert rating.rating == 5
      assert :ok = JidoChatBridge.handle_reaction_event(config, %{reaction | emoji: "👎"})
      updated = Conversations.get_rating(message, %{person_id: person.id})
      assert updated.id == rating.id
      assert updated.rating == 1

      assert {:ok, detail} =
               ChannelHistoryAdmin.dispatch(%{op: :detail, id: captured.transcript_id})

      assert [display] = detail.messages
      assert display.rating_summary == %{positive: 0, negative: 1}
      assert display.feedback == nil
      assert Conversations.get_rating(old, %{person_id: person.id}) == nil

      ref = %{
        provider: provider,
        channel_config_id: config.id,
        channel_id: "room",
        source_scope: scope,
        message_id: "post"
      }

      assert {:error, :not_found} = rate(%{ref | source_scope: "wrong"}, "rater")
      assert {:error, :unresolved_actor} = rate(ref, "unknown")
      assert {:error, :source_scope_mismatch} = rate(%{ref | channel_id: "other"}, "rater")
      assert {:error, :invalid_connector} = rate(%{ref | provider: "other"}, "rater")
      assert {:error, :not_found} = rate(%{ref | message_id: "missing"}, "rater")
      assert {:error, :invalid_source_scope} = rate(%{ref | source_scope: %{}}, "rater")
      assert {:error, :invalid_source_scope} = rate(ref, nil)
      {:ok, outsider} = People.create_person(%{full_name: "Outsider"})

      {:ok, _} =
        People.add_channel(%{
          person_id: outsider.id,
          platform: provider,
          channel_identifier: "outsider",
          channel_config_id: config.id
        })

      # A connector-resolved provider actor needs no separate history grant.
      assert {:ok, %{person_id: actor_id}} = rate(ref, "outsider")
      assert actor_id == outsider.id
      config |> ChannelConfig.changeset(%{enabled: false}) |> Repo.update!()
      assert {:error, :invalid_connector} = rate(ref, "rater")
    end
  end

  property "identical Telegram message IDs remain isolated by connector and native chat scope" do
    {:ok, person} = People.create_person(%{full_name: "Telegram rater"})

    configs =
      for n <- 1..2 do
        config =
          %ChannelConfig{}
          |> ChannelConfig.changeset(%{
            name: "Telegram #{n}",
            provider: "telegram",
            kind: "retrieval",
            url: "https://example.invalid",
            token: "token"
          })
          |> Repo.insert!()

        {:ok, _} =
          People.add_channel(%{
            person_id: person.id,
            platform: "telegram",
            channel_identifier: "rater",
            channel_config_id: config.id
          })

        config
      end

    check all(id <- positive_integer(), max_runs: 12) do
      targets =
        for config <- configs, room <- ["12345", "-67890"] do
          {:ok, facts} =
            Facts.new(%{
              provider: "telegram",
              channel_config_id: config.id,
              channel_id: room,
              kind: :direct,
              actor_person_id: person.id
            })

          {:ok, captured} =
            Conversations.capture_canonical_message(
              facts,
              %{role: "assistant", content: "Answer", external_message_id: to_string(id)},
              %{
                provider: "telegram",
                channel_config_id: config.id,
                provenance: "provider_delivery",
                source_scope: room
              }
            )

          {config, room, Repo.get!(Message, captured.message_id)}
        end

      [{config, room, selected} | others] = targets

      reaction =
        ReactionEvent.new(%{
          message_id: id,
          channel_id: "telegram:#{room}",
          thread: %{
            id: "telegram:#{room}",
            adapter_name: :telegram,
            adapter: __MODULE__,
            external_room_id: room
          },
          user: %{user_id: "rater", user_name: "Rater"},
          emoji: "👍"
        })

      assert :ok = JidoChatBridge.handle_reaction_event(config, reaction)
      assert Conversations.get_rating(selected, %{person_id: person.id}).rating == 5

      for {_, _, other} <- others,
          do: assert(Conversations.get_rating(other, %{person_id: person.id}) == nil)
    end
  end

  defp bridge_providers do
    configured =
      for {provider, %{bridge: JidoChatBridge}} <- Application.fetch_env!(:zaq, :channels),
          do: to_string(provider)

    Enum.uniq(["slack" | configured])
  end

  defp rate(ref, rater) do
    event =
      Event.new(
        %{message_ref: {:source, ref}, rater_attrs: %{channel_user_id: rater, rating: 5}},
        :engine
      )

    Api.handle_event(event, :rate_message, nil).response
  end
end

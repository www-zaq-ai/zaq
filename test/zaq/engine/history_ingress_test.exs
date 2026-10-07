defmodule Zaq.Engine.HistoryIngressTest do
  use Zaq.DataCase, async: false
  use Oban.Testing, repo: Zaq.Repo
  use ExUnitProperties

  alias Jido.Chat.Telegram.Adapter, as: TelegramAdapter
  alias Zaq.Accounts.People
  alias Zaq.Channels.{CommunicationBridge, JidoChatBridge}
  alias Zaq.Channels.EmailBridge
  alias Zaq.Channels.EmailBridge.ImapAdapter.Parser
  alias Zaq.Engine.Api
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.ChannelHistoryAdmin
  alias Zaq.Engine.{Conversations, HistoryDeliveryWorker, HistoryIngress, IncomingMessageRouter}
  alias Zaq.Engine.Conversations.{Message, Transcript, TranscriptMessage}
  alias Zaq.Engine.History.CommunicationPolicy
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event
  alias Zaq.Permissions
  alias Zaq.Permissions.ChannelHistoryResource

  defmodule NoopRouter do
    def fire(event), do: event
  end

  defmodule EmailIngressRouter do
    alias Zaq.Engine.Api

    def dispatch(%{opts: opts} = event) do
      send(self(), {:email_ingress_action, opts[:action]})

      case opts[:action] do
        :route_incoming_message -> %{event | response: :ok}
        action -> Api.handle_event(event, action, nil)
      end
    end
  end

  defp capture_delivered(delivery) do
    with {:ok, id} <-
           HistoryIngress.record_confirmation(Map.put(delivery, :confirmation, :confirmed)),
         {:ok, :ok} <- HistoryIngress.associate_confirmation(id) do
      message = Repo.get!(Message, id)

      targets =
        Map.new(message.metadata["history_association"]["transcript_ids"], fn target_id ->
          target = Repo.get!(Transcript, target_id)
          {target.owner_person_id, target.id}
        end)

      {:ok, %{message_id: id, transcript_ids: targets}}
    end
  end

  test "admission reuses source validation and confirmation reuses its locked response" do
    config = connector("mattermost")
    person = author("Query author", "mattermost", "query-author", config.id)

    incoming =
      Incoming.new(%{
        content: "question",
        channel_id: "query-room",
        author_id: "query-author",
        message_id: "query-input",
        provider: :mattermost,
        person: person,
        routing_context: %{channel_config_id: config.id, conversation_type: :room}
      })

    assert {:ok, captured} = HistoryIngress.capture(incoming)

    {{:ok, binding}, queries} =
      Zaq.QueryRecorder.capture(fn -> Conversations.admit_incoming(incoming) end)

    assert binding.user_message_id == captured.message_id
    assert Enum.count(queries, &(&1.source == "channel_configs")) == 1

    assert {:ok, %{assistant_message_id: assistant_id}} =
             Conversations.finalize_incoming(
               binding.user_message_id,
               binding.finalization_token,
               %{
                 answer: "answer",
                 error: false
               }
             )

    delivery = %{
      confirmation: :confirmed,
      provider: "mattermost",
      kind: :channel,
      channel_config_id: config.id,
      channel_id: "query-room",
      message_id: "query-response",
      content: "answer",
      user_message_id: binding.user_message_id,
      assistant_message_id: assistant_id
    }

    {{:ok, ^assistant_id}, queries} =
      Zaq.QueryRecorder.capture(fn -> HistoryIngress.record_confirmation(delivery) end)

    message_reads =
      Enum.filter(queries, &(&1.source == "messages" and String.starts_with?(&1.query, "SELECT")))

    assert length(message_reads) == 2
    assert {:ok, ^assistant_id} = HistoryIngress.record_confirmation(delivery)
    assert {:ok, :ok} = HistoryIngress.associate_confirmation(assistant_id)
    assert Repo.get!(Message, assistant_id).external_message_id == "query-response"
  end

  test "unscoped admission retains its existing post-insert side-effect boundary" do
    incoming =
      Incoming.new(%{
        content: "question",
        channel_id: "bo",
        provider: :web,
        author_id: "unscoped",
        message_id: "unscoped-input"
      })

    {{:ok, _binding}, queries} =
      Zaq.QueryRecorder.capture(fn -> Conversations.admit_incoming(incoming) end)

    assert [insert] =
             Enum.filter(
               queries,
               &(&1.source == "messages" and String.starts_with?(&1.query, "INSERT"))
             )

    refute insert.in_transaction
  end

  test "email recipient copies follow header threads across senders and separate identical subjects" do
    config = connector("email:imap")
    {:ok, sender} = People.create_person(%{full_name: "Sender", email: "sender@example.com"})
    {:ok, cc} = People.create_person(%{full_name: "CC Person", email: "cc@example.com"})

    make = fn from, id, refs ->
      incoming =
        Parser.to_incoming(
          %{
            from: %{address: from, name: "Header name"},
            to: "sender@example.com",
            cc: "cc@example.com",
            message_id: id,
            references: refs,
            subject: "Same subject",
            body_text: "Message #{id}"
          },
          config,
          mailbox: "INBOX"
        )

      %{
        incoming
        | routing_context: %{incoming.routing_context | conversation_type: :recipient_addressed}
      }
    end

    assert {:ok, root} =
             HistoryIngress.capture(make.("sender@example.com", "<root@example.com>", nil))

    assert Map.keys(root.transcript_ids) |> Enum.sort() == Enum.sort([sender.id, cc.id])

    assert {:ok, reply} =
             HistoryIngress.capture(
               make.("cc@example.com", "<reply@example.com>", "<root@example.com>")
             )

    assert reply.transcript_ids == root.transcript_ids

    assert {:ok, other} =
             HistoryIngress.capture(make.("sender@example.com", "<other@example.com>", nil))

    refute other.transcript_ids[sender.id] == root.transcript_ids[sender.id]

    assert Repo.aggregate(
             from(p in TranscriptMessage, where: p.message_id == ^root.message_id),
             :count
           ) == 2

    assert {:ok, rows} = ChannelHistoryAdmin.dispatch(%{op: :list})
    row = Enum.find(rows, &(&1.id == root.transcript_ids[sender.id]))
    assert row.channel_name == "Sender: Same subject"
    assert row.participant_count == 2
    assert Enum.any?(row.participants, &(&1.person_id == cc.id))
  end

  test "parser through outgoing and real SMTP replies to visible targets and confirms their thread copies" do
    config = connector("email:imap")
    smtp = Repo.get_by!(ChannelConfig, name: "History SMTP")

    smtp
    |> ChannelConfig.changeset(%{settings: %{"from_email" => "bot@example.com"}})
    |> Repo.update!()

    config =
      config
      |> ChannelConfig.changeset(%{
        settings: %{
          "imap" => %{
            "selected_mailboxes" => ["INBOX"],
            "smtp_config_id" => smtp.id,
            "username" => "login@example.com"
          }
        }
      })
      |> Repo.update!()

    raw = %{
      from: %{address: "sender@example.com", name: "Sender"},
      to: "bot@example.com, other@example.com",
      cc: "copied@example.com, other@example.com",
      reply_to: "reply@example.com",
      raw_header:
        "Delivered-To: bot-alias@example.com\r\nTo: bot-alias@example.com, login@example.com, bot@example.com, other@example.com\r\nCc: copied@example.com, other@example.com\r\nReply-To: reply@example.com",
      message_id: "<smtp-root@example.com>",
      subject: "Report",
      body_text: "Please reply to everyone"
    }

    incoming =
      EmailBridge.to_internal(raw, %{config: config, mailbox: "INBOX"})

    # Other configured SMTP senders are not evidence about this inbox's audience.
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "Unselected sender",
      provider: "email:smtp",
      kind: "retrieval",
      url: "https://example.invalid",
      token: "fixture-token",
      settings: %{"from_email" => "other@example.com"}
    })
    |> Repo.insert!()

    assert EmailBridge.to_internal(raw, %{config: config, mailbox: "INBOX"}) == incoming

    incoming = %{
      incoming
      | routing_context: %{incoming.routing_context | conversation_type: :recipient_addressed}
    }

    assert {:ok, root} = HistoryIngress.capture(incoming)

    for address <- ["bot@example.com", "bot-alias@example.com", "login@example.com"] do
      refute Repo.exists?(from p in Zaq.Accounts.Person, where: p.email == ^address)

      refute Repo.exists?(
               from c in Zaq.Accounts.PersonChannel, where: c.channel_identifier == ^address
             )

      refute address in incoming.routing_context.audience.recipients

      refute Enum.any?(
               incoming.routing_context.audience.participants,
               &(&1.identifier == address)
             )
    end

    assert map_size(root.transcript_ids) == 3
    incoming = CommunicationBridge.put_conversation_identity(incoming)
    assert {:ok, binding} = Conversations.admit_incoming(incoming)
    assert binding.user_message_id == root.message_id

    assert {:ok, %{assistant_message_id: assistant_id}} =
             Conversations.finalize_incoming(
               binding.user_message_id,
               binding.finalization_token,
               %{answer: "Here is the report", error: false}
             )

    outgoing =
      Outgoing.from_pipeline_result(incoming, %{answer: "Here is the report"})

    assert {:ok, receipt} = EmailBridge.send_reply(outgoing, %{})
    assert_receive {:email, email}
    assert email.to == [{"", "reply@example.com"}, {"", "other@example.com"}]
    assert email.cc == [{"", "copied@example.com"}]
    assert email.bcc == []
    assert email.from == {"ZAQ", "bot-alias@example.com"}
    assert email.headers["Auto-Submitted"] == "auto-replied"
    assert email.headers["In-Reply-To"] == "<smtp-root@example.com>"

    assert receipt.audience.recipients == [
             "reply@example.com",
             "other@example.com",
             "copied@example.com"
           ]

    assert receipt.conversation_id == incoming.routing_context.conversation_id

    # Historical bad discovery must not turn the assistant's transport sender
    # into a recipient of the confirmed response.
    {:ok, old_bot} =
      People.find_or_create_from_channel("email", %{
        channel_id: "bot-alias@example.com",
        channel_config_id: config.id
      })

    assert {:ok, replayed} = HistoryIngress.capture(incoming)
    refute Map.has_key?(replayed.transcript_ids, old_bot.id)

    assert {:ok, delivered} =
             capture_delivered(%{
               provider: "email:imap",
               channel_config_id: config.id,
               kind: :replicated,
               channel_id: "reply@example.com",
               conversation_id: receipt.conversation_id,
               message_id: receipt.message_id,
               assistant_message_id: assistant_id,
               content: outgoing.body,
               audience: receipt.audience,
               source_scope: receipt.source_scope
             })

    {:ok, copied} = People.match_by_channel("email", "copied@example.com", config.id)
    refute Map.has_key?(delivered.transcript_ids, old_bot.id)
    refute Repo.exists?(from t in Transcript, where: t.owner_person_id == ^old_bot.id)

    refute Repo.exists?(
             from g in Zaq.Permissions.ResourcePermission, where: g.person_id == ^old_bot.id
           )

    assert delivered.message_id == assistant_id

    reference = %{
      provider: "email:imap",
      channel_config_id: config.id,
      source_scope: receipt.source_scope,
      message_id: receipt.message_id
    }

    assert {:ok, true} = HistoryIngress.confirmed_delivery?(reference)

    assert {:ok, false} =
             HistoryIngress.confirmed_delivery?(%{reference | message_id: "unknown@example.com"})

    assert {:ok, false} =
             HistoryIngress.confirmed_delivery?(
               Map.merge(reference, %{
                 source_scope: "another-mailbox",
                 assistant_message_id: assistant_id
               })
             )

    other = connector("email:imap")

    assert {:ok, false} =
             HistoryIngress.confirmed_delivery?(%{reference | channel_config_id: other.id})

    assert {:error, :invalid_delivery_scope} =
             HistoryIngress.confirmed_delivery?(%{reference | provider: "telegram"})

    assert {:error, :invalid_delivery_scope} = HistoryIngress.confirmed_delivery?(%{})

    assert {:ok, false} =
             HistoryIngress.confirmed_delivery?(%{
               reference
               | source_scope: "INBOX",
                 message_id: "smtp-root@example.com"
             })

    previous_pipeline = Application.fetch_env(:zaq, :email_bridge_pipeline_module)
    previous_router = Application.fetch_env(:zaq, :email_bridge_node_router_module)
    Application.put_env(:zaq, :email_bridge_pipeline_module, Zaq.Agent.Pipeline)
    Application.put_env(:zaq, :email_bridge_node_router_module, EmailIngressRouter)

    on_exit(fn ->
      for {key, previous} <- [
            email_bridge_pipeline_module: previous_pipeline,
            email_bridge_node_router_module: previous_router
          ] do
        case previous do
          {:ok, value} -> Application.put_env(:zaq, key, value)
          :error -> Application.delete_env(:zaq, key)
        end
      end
    end)

    echoed = %{
      from: %{address: "bot@example.com"},
      message_id: receipt.message_id,
      body_text: outgoing.body,
      raw_header:
        "Delivered-To: bot-alias@example.com\r\nTo: other@example.com\r\nAuto-Submitted: auto-replied"
    }

    count = Repo.aggregate(Message, :count)
    assert :ok = EmailBridge.handle_from_listener(config, echoed, mailbox: "INBOX")
    assert_received {:email_ingress_action, :confirmed_history_delivery}
    refute_received {:email_ingress_action, :capture_incoming_history}
    refute_received {:email_ingress_action, :route_incoming_message}
    assert Repo.aggregate(Message, :count) == count
    refute_received {:email, _}

    assert :ok =
             EmailBridge.handle_from_listener(
               config,
               %{echoed | raw_header: "To: other@example.com"},
               mailbox: "INBOX"
             )

    assert Repo.aggregate(Message, :count) == count
    refute_received {:email_ingress_action, :capture_incoming_history}
    refute_received {:email_ingress_action, :route_incoming_message}

    # The automatic-reply header stops generation even before a confirmation is available.
    assert :ok =
             EmailBridge.handle_from_listener(
               config,
               %{echoed | message_id: "early-auto@example.com"},
               mailbox: "INBOX"
             )

    assert_received {:email_ingress_action, :receive_incoming_message}
    refute_received {:email_ingress_action, :route_incoming_message}
    refute_received {:email, _}

    human = %{
      echoed
      | from: %{address: "login@example.com"},
        message_id: "zaq-human@example.com",
        raw_header: "To: other@example.com"
    }

    assert :ok = EmailBridge.handle_from_listener(config, human, mailbox: "INBOX")
    assert_received {:email_ingress_action, :route_incoming_message}
    {:ok, reply} = People.match_by_channel("email", "reply@example.com", config.id)
    {:ok, sender} = People.match_by_channel("email", "sender@example.com", config.id)
    assert delivered.transcript_ids[copied.id] == root.transcript_ids[copied.id]
    assert delivered.transcript_ids[reply.id]
    refute delivered.transcript_ids[sender.id]

    refute Repo.exists?(
             from p in TranscriptMessage,
               where:
                 p.transcript_id == ^delivered.transcript_ids[reply.id] and
                   p.message_id == ^root.message_id
           )
  end

  test "reply From preserves the receiving alias while the main account remains the SMTP connector" do
    config = connector("email:imap")
    smtp = Repo.get_by!(ChannelConfig, name: "History SMTP")

    smtp
    |> ChannelConfig.changeset(%{settings: %{"from_email" => "julien@eweev.com"}})
    |> Repo.update!()

    config =
      config
      |> ChannelConfig.changeset(%{
        settings: %{
          "imap" => %{
            "smtp_config_id" => smtp.id,
            "selected_mailboxes" => ["INBOX"],
            "username" => "julien@eweev.com"
          }
        }
      })
      |> Repo.update!()

    incoming =
      Parser.to_incoming(
        %{
          from: %{address: "julien@fayad.fr"},
          message_id: "<alias-regression@example.com>",
          raw_header:
            "Delivered-To: zaq-local@eweev.com\r\nTo: zaq-local@eweev.com\r\nCc: j.tarabay@zaq.ai",
          body_text: "Reply to everyone"
        },
        config,
        mailbox: "INBOX"
      )

    outgoing = Outgoing.from_pipeline_result(incoming, %{answer: "Reply"})

    assert {:ok, receipt} = EmailBridge.send_reply(outgoing, %{})
    assert_receive {:email, email}
    assert email.from == {"ZAQ", "zaq-local@eweev.com"}
    assert email.to == [{"", "julien@fayad.fr"}]
    assert email.cc == [{"", "j.tarabay@zaq.ai"}]
    assert email.bcc == []
    assert email.headers["Auto-Submitted"] == "auto-replied"
    assert receipt.audience.sender == "zaq-local@eweev.com"
    assert receipt.audience.recipients == ["julien@fayad.fr", "j.tarabay@zaq.ai"]
    assert Repo.get!(ChannelConfig, config.id).settings["imap"]["smtp_config_id"] == smtp.id
    assert Repo.get!(ChannelConfig, smtp.id).settings["from_email"] == "julien@eweev.com"
  end

  test "reply filtering leaves no destination rather than falling back to the original sender" do
    config = connector("email:imap")
    smtp = Repo.get_by!(ChannelConfig, name: "History SMTP")

    smtp
    |> ChannelConfig.changeset(%{settings: %{"from_email" => "bot@example.com"}})
    |> Repo.update!()

    config =
      config
      |> ChannelConfig.changeset(%{
        settings: %{"imap" => %{"smtp_config_id" => smtp.id, "selected_mailboxes" => ["INBOX"]}}
      })
      |> Repo.update!()

    incoming =
      Parser.to_incoming(
        %{
          from: %{address: "bot@example.com"},
          raw_header:
            "Delivered-To: alias@example.com\r\nTo: alias@example.com\r\nCc: bot@example.com",
          body_text: "Echo"
        },
        config,
        mailbox: "INBOX"
      )

    outgoing = Outgoing.from_pipeline_result(incoming, %{answer: "Must not be sent"})
    assert {:error, :no_reply_recipients} = EmailBridge.send_reply(outgoing, %{})
    refute_received {:email, _}
  end

  test "real Telegram adapter IDs capture private, group and topic history idempotently" do
    config = connector("telegram")
    person = author("Telegram author", "telegram", "456", config.id)

    for {type, room, topic} <- [
          {"private", 123, nil},
          {"group", -123, nil},
          {"supergroup", -100_123, 9}
        ] do
      payload = %{
        "message" => %{
          "message_id" => 42,
          "chat" => %{"id" => room, "type" => type},
          "from" => %{"id" => 456},
          "text" => "Telegram history",
          "message_thread_id" => topic
        }
      }

      assert {:ok, transport} = TelegramAdapter.transform_incoming(payload)
      incoming = JidoChatBridge.to_internal(transport, config)
      assert incoming.channel_id == to_string(room)

      assert {:ok, captured} =
               HistoryIngress.capture_resolved(
                 incoming,
                 person.id,
                 elem(CommunicationPolicy.kind(incoming), 1)
               )

      assert {:ok, ^captured} =
               HistoryIngress.capture_resolved(
                 incoming,
                 person.id,
                 elem(CommunicationPolicy.kind(incoming), 1)
               )

      transcript = Repo.get!(Transcript, captured.transcript_id)
      assert transcript.external_channel_id == to_string(room)
      assert transcript.external_thread_id == if(topic, do: to_string(topic), else: nil)

      if type == "private" do
        assert {:ok, rows} = ChannelHistoryAdmin.dispatch(%{op: :list})
        row = Enum.find(rows, &(&1.id == captured.transcript_id))
        assert row.channel_name == "Telegram author"
        assert row.connector == config.name
      end

      incoming =
        CommunicationBridge.put_conversation_identity(%{incoming | person: %{id: person.id}})

      assert {:ok, admitted} = Conversations.admit_incoming(incoming)
      assert admitted.user_message_id == captured.message_id
      assert {:ok, replay} = Conversations.admit_incoming(incoming)
      assert replay.user_message_id == admitted.user_message_id
      refute replay.admitted?
    end

    assert Repo.aggregate(Message, :count) == 3
    assert Repo.aggregate(TranscriptMessage, :count) == 3
  end

  defp connector(provider) do
    if provider == "email:imap" do
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "History SMTP",
        provider: "email:smtp",
        kind: "retrieval",
        url: "https://example.invalid",
        token: "test-token"
      })
      |> Repo.insert!()
    end

    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "History ingress #{System.unique_integer([:positive])}",
      provider: provider,
      kind: "retrieval",
      url: "https://example.invalid",
      token: "test-token",
      settings:
        if(provider == "email:imap",
          do: %{"imap" => %{"selected_mailboxes" => ["INBOX"]}},
          else: %{}
        )
    })
    |> Repo.insert!()
  end

  defp author(name, provider, identifier, config_id) do
    {:ok, person} = People.create_person(%{"full_name" => name})

    {:ok, _} =
      People.add_channel(%{
        "person_id" => person.id,
        "platform" => provider,
        "channel_identifier" => identifier,
        "channel_config_id" => config_id
      })

    person
  end

  test "passive shared nonmention persists without admitting a turn or granting the author access" do
    config = connector("mattermost")
    person = author("Alex", "mattermost", "alex-1", config.id)

    incoming =
      Incoming.new(%{
        content: "Deploy notes for the team",
        channel_id: "room-1",
        author_id: "alex-1",
        message_id: "post-1",
        provider: :mattermost,
        routing_context: %{channel_config_id: config.id, conversation_type: :room}
      })

    assert {:ok, captured} = HistoryIngress.capture(incoming)
    assert {:ok, ^captured} = HistoryIngress.capture(incoming)
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.aggregate(TranscriptMessage, :count) == 1

    assert {:error, :unauthorized} =
             Conversations.list_canonical_messages(person, captured.transcript_id)

    resource = ChannelHistoryResource.for("mattermost", config.id, "room-1")

    assert {:ok, _} =
             Permissions.grant(resource, %{person_id: person.id, access_rights: ["read"]})

    assert {:ok, [%{content: "Deploy notes for the team"}]} =
             Conversations.list_canonical_messages(person, captured.transcript_id)
  end

  test "unsupported room type does not mint a transcript" do
    config = connector("mattermost")

    incoming =
      Incoming.new(%{
        content: "unproven",
        channel_id: "room-1",
        provider: :mattermost,
        author_id: "alex",
        routing_context: %{channel_config_id: config.id}
      })

    assert {:error, :unsupported_history_kind} = HistoryIngress.capture(incoming)
    assert Repo.aggregate(Message, :count) == 0
  end

  test "passive capture dispatch has no reply or routing hop" do
    config = connector("mattermost")
    author("Alex", "mattermost", "alex-1", config.id)

    incoming =
      Incoming.new(%{
        content: "silent note",
        channel_id: "room-1",
        provider: :mattermost,
        author_id: "alex-1",
        message_id: "post-2",
        routing_context: %{channel_config_id: config.id, conversation_type: :room}
      })

    event = Event.new(incoming, :engine, opts: [action: :capture_incoming_history])

    result = Api.handle_event(event, :capture_incoming_history, %{})
    assert %{response: {:ok, %{message_id: _}}, next_hop: nil} = result
    assert Repo.aggregate(Message, :count) == 1
  end

  test "addressed Engine routing captures before resolving a response" do
    config = connector("mattermost")
    author("Alex", "mattermost", "alex-1", config.id)

    incoming =
      Incoming.new(%{
        content: "@zaq hello",
        channel_id: "room-1",
        provider: :mattermost,
        author_id: "alex-1",
        message_id: "post-3",
        routing_context: %{channel_config_id: config.id, conversation_type: :room}
      })

    event =
      Event.new(incoming, :engine,
        opts: [action: :route_incoming_message, node_router: NoopRouter]
      )

    result = IncomingMessageRouter.route(event)

    refute match?({:error, _}, result.response)
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.aggregate(TranscriptMessage, :count) == 1
  end

  test "email sender and visible recipient receive distinct authorized histories" do
    config = connector("email:imap")
    sender = author("Sender", "email", "sender@example.com", config.id)
    recipient = author("Recipient", "email", "visible@example.com", config.id)
    excluded = author("Hidden", "email", "hidden@example.com", config.id)

    incoming =
      Incoming.new(%{
        content: "per-message audience",
        channel_id: "mail-thread",
        author_id: "sender@example.com",
        message_id: "mail-1",
        provider: :"email:imap",
        routing_context: %{
          channel_config_id: config.id,
          conversation_type: :recipient_addressed,
          topic_id: "INBOX",
          source_scope: "INBOX",
          identity_platform: "email",
          audience: %{
            platform: "email",
            sender: "sender@example.com",
            recipients: ["visible@example.com"]
          }
        }
      })

    assert {:ok, %{transcript_ids: ids}} = HistoryIngress.capture(incoming)
    assert Map.keys(ids) |> Enum.sort() == Enum.sort([sender.id, recipient.id])

    assert {:ok, [%{content: "per-message audience"}]} =
             Conversations.list_canonical_messages(sender, ids[sender.id])

    assert {:ok, [%{content: "per-message audience"}]} =
             Conversations.list_canonical_messages(recipient, ids[recipient.id])

    refute Map.has_key?(ids, excluded.id)
  end

  test "confirmed outbound mail targets only its actual message recipients when the sender is not linked" do
    config = connector("email:imap")
    first = author("First", "email", "first@example.com", config.id)
    later = author("Later", "email", "later@example.com", config.id)

    common = %{
      provider: "email:imap",
      kind: :replicated,
      source_scope: "smtp:confirmed",
      channel_config_id: config.id,
      channel_id: "first@example.com",
      content: "confirmed first delivery",
      message_id: "sent-1",
      audience: %{
        platform: "email",
        sender: "system@example.com",
        recipients: ["first@example.com"]
      }
    }

    assert {:ok, capture} = capture_delivered(common)
    assert {:ok, ^capture} = capture_delivered(common)

    assert {:ok, [%{content: "confirmed first delivery"}]} =
             Conversations.list_canonical_messages(first, capture.transcript_ids[first.id])

    refute Map.has_key?(capture.transcript_ids, later.id)

    second = %{
      common
      | message_id: "sent-2",
        content: "later message",
        audience: %{common.audience | recipients: ["first@example.com", "later@example.com"]}
    }

    assert {:ok, later_capture} = capture_delivered(second)

    assert {:ok, [%{content: "later message"}]} =
             Conversations.list_canonical_messages(later, later_capture.transcript_ids[later.id])

    assert Repo.aggregate(Message, :count) == 2

    assert {:error, :conflicting_delivery_confirmation} =
             capture_delivered(%{
               common
               | audience: %{common.audience | recipients: ["hidden@example.com"]}
             })
  end

  test "reference-only recovery retains the original audience across identity relinking" do
    config = connector("email:imap")
    first = author("Original", "email", "first@example.com", config.id)

    delivery = %{
      confirmation: :confirmed,
      provider: "email:imap",
      kind: :replicated,
      source_scope: "smtp:confirmed",
      channel_config_id: config.id,
      channel_id: "first@example.com",
      content: "persist once",
      message_id: "confirmed-1",
      audience: %{
        platform: "email",
        sender: "system@example.com",
        recipients: ["first@example.com"]
      }
    }

    assert {:error, :abort_confirmation} =
             Repo.transaction(fn ->
               assert {:ok, _} = HistoryIngress.record_confirmation(delivery)
               Repo.rollback(:abort_confirmation)
             end)

    assert Repo.aggregate(Message, :count) == 0
    assert Repo.aggregate(Transcript, :count) == 0
    refute_enqueued(worker: HistoryDeliveryWorker)

    results =
      1..2
      |> Task.async_stream(fn _ -> HistoryIngress.record_confirmation(delivery) end,
        max_concurrency: 2
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, message_id}, {:ok, same_id}] = results
    assert message_id == same_id
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.aggregate(TranscriptMessage, :count) == 0

    assert [%{args: %{"message_id" => ^message_id}}] =
             all_enqueued(worker: HistoryDeliveryWorker)

    stored = Repo.get!(Message, message_id)
    assert stored.content == "persist once"
    [target_id] = stored.metadata["history_association"]["transcript_ids"]

    for channel <- People.list_person_channels(first.id), do: People.delete_channel(channel)
    replacement = author("Replacement", "email", "first@example.com", config.id)
    assert {:ok, ^message_id} = HistoryIngress.record_confirmation(delivery)
    assert {:ok, :ok} = HistoryIngress.associate_confirmation(message_id)
    assert {:ok, :ok} = HistoryIngress.associate_confirmation(message_id)
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.aggregate(TranscriptMessage, :count) == 1
    for job <- all_enqueued(worker: HistoryDeliveryWorker), do: Repo.delete!(job)
    assert {:ok, :ok} = HistoryIngress.associate_confirmation(message_id)

    assert Repo.get!(Message, message_id).metadata["delivery_confirmation"]["message_id"] ==
             "confirmed-1"

    assert {:ok, [%{message_id: ^message_id}]} =
             Conversations.list_canonical_messages(first, target_id)

    assert {:error, :unauthorized} = Conversations.list_canonical_messages(replacement, target_id)

    assert {:error, :conflicting_delivery_confirmation} =
             HistoryIngress.record_confirmation(%{delivery | content: "changed"})
  end

  property "confirmation replays keep one message, target and reference-only job" do
    check all(
            body <- string(:alphanumeric, min_length: 1, max_length: 300),
            attempts <- integer(1..4),
            max_runs: 12
          ) do
      config = connector("email:imap")

      {:ok, recipient} =
        People.find_or_create_from_channel("email", %{
          channel_id: "recipient@example.com",
          email: "recipient@example.com",
          channel_config_id: config.id
        })

      delivery = %{
        confirmation: :confirmed,
        provider: "email:imap",
        kind: :replicated,
        channel_config_id: config.id,
        channel_id: "recipient@example.com",
        source_scope: "smtp:confirmed",
        message_id: "property-message",
        content: body,
        audience: %{
          platform: "email",
          sender: "system@example.com",
          recipients: ["recipient@example.com"]
        }
      }

      assert {:ok, id} = HistoryIngress.record_confirmation(delivery)

      for _ <- 1..attempts do
        assert {:ok, ^id} = HistoryIngress.record_confirmation(delivery)
        assert {:ok, :ok} = HistoryIngress.capture_confirmed(delivery)
      end

      assert [%{transcript_id: target_id}] =
               Repo.all(from p in TranscriptMessage, where: p.message_id == ^id)

      assert Repo.get!(Transcript, target_id).owner_person_id == recipient.id

      assert [%{args: %{"message_id" => ^id}}] =
               Enum.filter(
                 all_enqueued(worker: HistoryDeliveryWorker),
                 &(&1.args["message_id"] == id)
               )

      assert Repo.get!(Message, id).content == body
    end
  end

  test "confirmed agent email reply reuses its persisted assistant UUID without exposing previous recipients" do
    config = connector("email:imap")
    correspondent = author("Correspondent", "email", "correspondent@example.com", config.id)
    previous = author("Other", "email", "previous@example.com", config.id)

    incoming =
      Incoming.new(%{
        content: "question",
        channel_id: "correspondent@example.com",
        author_id: "correspondent@example.com",
        message_id: "incoming-1",
        provider: :"email:imap",
        metadata: %{"email" => %{"mailbox" => "INBOX"}},
        routing_context: %{
          channel_config_id: config.id,
          conversation_type: :recipient_addressed,
          topic_id: "INBOX",
          source_scope: "INBOX",
          identity_platform: "email",
          audience: %{
            platform: "email",
            sender: "correspondent@example.com",
            recipients: ["previous@example.com"]
          }
        }
      })

    assert {:ok, input} = HistoryIngress.capture(incoming)
    assert {:ok, binding} = Conversations.admit_incoming(incoming)
    assert input.message_id == binding.user_message_id

    assert {:ok, %{assistant_message_id: assistant_id}} =
             Conversations.finalize_incoming(
               binding.user_message_id,
               binding.finalization_token,
               %{
                 answer: "email answer",
                 error: false
               }
             )

    assert {:ok, outbound} =
             capture_delivered(%{
               provider: "email:imap",
               kind: :replicated,
               source_scope: "smtp:confirmed",
               channel_config_id: config.id,
               channel_id: "correspondent@example.com",
               audience: %{
                 platform: "email",
                 sender: "support@example.com",
                 recipients: ["correspondent@example.com"]
               },
               message_id: "smtp-1",
               content: "email answer",
               assistant_message_id: assistant_id
             })

    assert outbound.message_id == assistant_id

    assert {:error, :conflicting_delivery_confirmation} =
             capture_delivered(%{
               provider: "email:imap",
               kind: :replicated,
               source_scope: "smtp:confirmed",
               channel_config_id: config.id,
               channel_id: "correspondent@example.com",
               audience: %{
                 platform: "email",
                 sender: "different@example.com",
                 recipients: ["correspondent@example.com"]
               },
               message_id: "smtp-1",
               content: "email answer",
               assistant_message_id: assistant_id
             })

    assert {:ok, [%{content: "question"}, %{content: "email answer"}]} =
             Conversations.list_canonical_messages(
               correspondent,
               outbound.transcript_ids[correspondent.id]
             )

    assert {:ok, [%{content: "question"}]} =
             Conversations.list_canonical_messages(previous, input.transcript_ids[previous.id])

    assert Repo.aggregate(Message, :count) == 2
  end
end

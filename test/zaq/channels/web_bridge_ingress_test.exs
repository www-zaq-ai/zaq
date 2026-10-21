defmodule Zaq.Channels.WebBridgeIngressTest do
  use Zaq.DataCase, async: true

  import Zaq.AccountsFixtures

  alias Zaq.Channels.Api
  alias Zaq.Channels.Web.{Command, Context, Delivery, Message, Response}
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Event
  alias ZaqWeb.Chat.BridgeClient

  @assistant_id "11111111-1111-4111-8111-111111111111"

  defmodule LocalNodeRouter do
    alias Zaq.Engine.Api, as: EngineApi
    alias Zaq.Engine.Messages.Outgoing
    alias Zaq.Event

    def dispatch(%Event{opts: opts} = event) do
      case Keyword.fetch!(opts, :action) do
        :web_ingress ->
          Zaq.Channels.Api.handle_event(event, :web_ingress, nil)

        :route_incoming_message ->
          send(self(), {:engine_routing_event, event})

          %{
            event
            | response: %Outgoing{
                body: "answer",
                channel_id: event.request.channel_id,
                provider: :web,
                in_reply_to: event.request.message_id,
                routing_context: event.request.routing_context,
                metadata:
                  Map.put(
                    event.request.metadata,
                    :assistant_message_id,
                    "11111111-1111-4111-8111-111111111111"
                  )
              }
          }

        :conversation ->
          send(self(), {:engine_conversation_event, event})

          if Process.get(:engine_unavailable) do
            %{event | response: {:error, :engine_unavailable}}
          else
            EngineApi.handle_event(event, :conversation, nil)
          end
      end
    end
  end

  describe ":web_ingress" do
    test "returns unsupported when the configured web bridge is unavailable" do
      actor = %{user_id: 42}
      assert {:ok, context} = Context.new(actor, consumer: :bo)

      assert {:ok, command} =
               Command.new(%{request_id: "unsupported-1", type: :conversation_init})

      event =
        Event.new(%{payload: command, context: context}, :channels,
          actor: actor,
          opts: [action: :web_ingress, web_bridge_module: Zaq.Channels.NotLoadedWebBridge]
        )

      assert Api.handle_event(event, :web_ingress, nil).response == {:error, :unsupported}
      refute_received {:engine_conversation_event, _}
    end

    test "rejects a missing or wrong-shaped ingress payload" do
      assert Api.handle_event(Event.new(%{payload: nil}, :channels), :web_ingress, nil).response ==
               {:error, :invalid_web_ingress}

      assert Api.handle_event(Event.new(%{payload: %{}}, :channels), :web_ingress, nil).response ==
               {:error, :invalid_web_ingress}
    end

    test "BO client dispatches through the Channels role instead of invoking WebBridge" do
      actor = %{user_id: 42, person: %{id: 7, full_name: "Ada", team_ids: []}}

      assert %Outgoing{} =
               BridgeClient.dispatch_message(
                 %{
                   request_id: "request-client",
                   message_id: "message-client",
                   content: "question",
                   timestamp: DateTime.utc_now(),
                   channel: "bo",
                   mode: :sync,
                   author_id: "42"
                 },
                 actor,
                 consumer: :bo,
                 capabilities: [:skip_permissions],
                 delivery: Delivery.bo("chat:session-client"),
                 node_router: LocalNodeRouter
               )

      assert_received {:engine_routing_event, %Event{request: %Incoming{}}}

      assert {:error, {:invalid_field, :type}} =
               BridgeClient.dispatch_command(
                 %{request_id: "invalid", type: "message.edit"},
                 actor,
                 consumer: :bo,
                 node_router: LocalNodeRouter
               )
    end

    test "routes a normalized BO message as canonical Incoming with trusted options", %{test: _} do
      actor = %{user_id: 42, person: %{id: 7, full_name: "Ada", team_ids: [3]}}
      delivery = Delivery.bo("chat:session-1")

      assert {:ok, context} =
               Context.new(actor,
                 consumer: :bo,
                 capabilities: [:skip_permissions],
                 delivery: delivery,
                 selected_agent_id: "agent-1",
                 content_filter: ["docs/legal"],
                 history: %{question: "previous answer"}
               )

      assert {:ok, message} =
               Message.new(%{
                 request_id: "request-1",
                 message_id: "message-1",
                 content: "question",
                 timestamp: DateTime.utc_now(),
                 channel: "bo",
                 mode: :sync,
                 conversation_id: Ecto.UUID.generate(),
                 author_id: "42",
                 author_name: "Ada"
               })

      event =
        Event.new(%{payload: message, context: context}, :channels,
          actor: actor,
          opts: [action: :web_ingress, node_router: LocalNodeRouter]
        )

      assert %Outgoing{} = Api.handle_event(event, :web_ingress, nil).response

      assert_received {:engine_routing_event,
                       %Event{
                         request: %Incoming{} = incoming,
                         actor: ^actor,
                         opts: engine_opts
                       }}

      assert incoming.content == "question"
      assert incoming.provider == :web
      assert incoming.message_id == "message-1"
      assert incoming.content_filter == ["docs/legal"]
      assert incoming.routing_context.conversation_id == message.conversation_id

      assert Map.take(incoming.routing_context.attributes, [
               "configured_agent_id",
               "routing_source"
             ]) == %{
               "configured_agent_id" => "agent-1",
               "routing_source" => "bo_explicit"
             }

      assert incoming.routing_context.attributes["web_delivery"]["topic"] == "chat:session-1"

      assert incoming.metadata[:request_id] == "request-1"
      assert incoming.metadata[:session_id] == "session-1"
      assert engine_opts[:pipeline_opts][:history] == %{question: "previous answer"}
      assert engine_opts[:pipeline_opts][:skip_permissions] == true
      assert engine_opts[:pipeline_opts][:node_router] == LocalNodeRouter
    end

    test "rejects a context whose actor does not match the event actor" do
      assert {:ok, context} = Context.new(%{user_id: 1}, consumer: :bo)

      assert {:ok, command} =
               Command.new(%{request_id: "request-1", type: :conversation_init})

      event =
        Event.new(%{payload: command, context: context}, :channels,
          actor: %{user_id: 2},
          opts: [action: :web_ingress, node_router: LocalNodeRouter]
        )

      assert Api.handle_event(event, :web_ingress, nil).response == {:error, :unauthorized}
      refute_received {:engine_conversation_event, _}
    end

    test "initializes and restores a BO conversation without entering message routing" do
      user = user_fixture()
      actor = %{user_id: user.id}
      assert {:ok, context} = Context.new(actor, consumer: :bo)

      assert {:ok, init} = Command.new(%{request_id: "init-1", type: :conversation_init})

      init_event =
        Event.new(%{payload: init, context: context}, :channels,
          actor: actor,
          opts: [action: :web_ingress, node_router: LocalNodeRouter]
        )

      assert %Response{
               type: :conversation_initialized,
               conversation_id: conversation_id,
               payload: %{created: true}
             } = Api.handle_event(init_event, :web_ingress, nil).response

      conversation = Conversations.get_conversation!(conversation_id)
      assert conversation.user_id == user.id
      assert conversation.channel_user_id == "bo_user_#{user.id}"

      {:ok, persisted} =
        Conversations.add_message(conversation, %{role: "user", content: "Persisted question"})

      assert {:ok, history} =
               Command.new(%{
                 request_id: "history-1",
                 type: :conversation_history,
                 conversation_id: conversation_id
               })

      history_event =
        Event.new(%{payload: history, context: context}, :channels,
          actor: actor,
          opts: [action: :web_ingress, node_router: LocalNodeRouter, confidential: true]
        )

      assert %{response: {:error, :confidential_event_required}} =
               Api.handle_event(
                 %{history_event | opts: Keyword.delete(history_event.opts, :confidential)},
                 :web_ingress,
                 nil
               )

      assert %Response{
               type: :conversation_history,
               conversation_id: ^conversation_id,
               payload: %{messages: [%{id: message_id, content: "Persisted question"}]}
             } = Api.handle_event(history_event, :web_ingress, nil).response

      assert message_id == persisted.id

      assert_received {:engine_conversation_event,
                       %Event{request: %{action: :display_history}, opts: opts}}

      assert opts[:confidential] == true
      refute_received {:engine_routing_event, _}
    end

    test "BO initialization rejects missing and inaccessible ids without replacement creation" do
      user = user_fixture()
      actor = %{user_id: user.id}
      assert {:ok, context} = Context.new(actor, consumer: :bo)
      missing_id = Ecto.UUID.generate()

      assert {:ok, init} =
               Command.new(%{
                 request_id: "init-missing",
                 type: :conversation_init,
                 conversation_id: missing_id
               })

      event =
        Event.new(%{payload: init, context: context}, :channels,
          actor: actor,
          opts: [action: :web_ingress, node_router: LocalNodeRouter]
        )

      assert %Response{type: :error, payload: %{code: :not_found}} =
               Api.handle_event(event, :web_ingress, nil).response

      other = user_fixture()

      {:ok, conversation} =
        Conversations.create_conversation(%{user_id: other.id, channel_type: "bo"})

      inaccessible = %{init | conversation_id: conversation.id}

      assert %Response{type: :error, payload: %{code: :not_found}} =
               Api.handle_event(
                 %{event | request: %{payload: inaccessible, context: context}},
                 :web_ingress,
                 nil
               ).response

      refute_received {:engine_conversation_event, %Event{request: %{action: :create}}}
    end

    test "BO resume resolves access without querying messages, ratings or execution evidence" do
      user = user_fixture()

      {:ok, conversation} =
        Conversations.create_conversation(%{user_id: user.id, channel_type: "bo"})

      {:ok, _} =
        Conversations.add_message(conversation, %{
          role: "assistant",
          content: "answer",
          trace: [%{"private" => "secret"}]
        })

      actor = %{user_id: user.id}
      {:ok, context} = Context.new(actor, consumer: :bo)

      {:ok, command} =
        Command.new(%{
          request_id: "resume",
          type: :conversation_init,
          conversation_id: conversation.id
        })

      event =
        Event.new(%{payload: command, context: context}, :channels,
          actor: actor,
          opts: [action: :web_ingress, node_router: LocalNodeRouter]
        )

      handler_id = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(
          handler_id,
          [:zaq, :repo, :query],
          &__MODULE__.capture_resume_query/4,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert %Response{type: :conversation_initialized, payload: %{created: false} = payload} =
               Api.handle_event(event, :web_ingress, nil).response

      assert payload == %{created: false}
      queries = resume_queries()
      assert Enum.any?(queries, &String.contains?(&1, ~s(FROM "conversations")))

      refute Enum.any?(queries, fn query ->
               Enum.any?(
                 ~w(messages message_ratings execution_records message_trace_artifacts),
                 &String.contains?(query, ~s("#{&1}"))
               )
             end)

      assert_receive {:engine_conversation_event,
                      %Event{request: %{action: :resolve_display_conversation}, opts: opts}}

      assert opts[:confidential]
      refute_received {:engine_conversation_event, _}
    end

    test "returns a structured response when Engine conversation dispatch fails" do
      user = user_fixture()
      actor = %{user_id: user.id}
      assert {:ok, context} = Context.new(actor, consumer: :bo)
      assert {:ok, command} = Command.new(%{request_id: "init-failed", type: :conversation_init})
      Process.put(:engine_unavailable, true)

      event =
        Event.new(%{payload: command, context: context}, :channels,
          actor: actor,
          opts: [action: :web_ingress, node_router: LocalNodeRouter]
        )

      assert %Response{
               type: :error,
               request_id: "init-failed",
               payload: %{code: :engine_unavailable}
             } = Api.handle_event(event, :web_ingress, nil).response
    end
  end

  def capture_resume_query(_event, _measurements, metadata, owner) do
    if self() == owner, do: send(owner, {:resume_query, metadata.query})
  end

  defp resume_queries do
    receive do
      {:resume_query, query} -> [query | resume_queries()]
    after
      0 -> []
    end
  end

  describe "normalized delivery" do
    test "round-trips final and streaming responses to the trusted BO topic" do
      actor = %{user_id: 42, person: %{id: 7, full_name: "Ada", team_ids: []}}
      topic = "chat:#{Ecto.UUID.generate()}"
      Phoenix.PubSub.subscribe(Zaq.PubSub, topic)

      assert %Outgoing{} = outgoing = dispatch_shared_message(actor, topic)

      final_event = Event.new(outgoing, :channels, opts: [action: :deliver_outgoing])

      assert {:ok, %{delivered: true}} =
               Api.handle_event(final_event, :deliver_outgoing, nil).response

      assert_receive {:web_response, :pipeline_result,
                      %Response{
                        type: :message_complete,
                        request_id: "request-roundtrip",
                        message_id: @assistant_id,
                        payload: %{body: "answer"}
                      }}

      status_outgoing = %{
        outgoing
        | body: "Current full answer",
          metadata:
            Map.merge(outgoing.metadata, %{
              update_intent: :stream_delta,
              intent_meta: %{stage: :answering}
            })
      }

      status_event = Event.new(status_outgoing, :channels, opts: [action: :upsert_message])

      assert {:ok, %{action: :created, message_id: @assistant_id}} =
               Api.handle_event(status_event, :upsert_message, nil).response

      assert_receive {:web_response, :status_update,
                      %Response{
                        type: :message_edit,
                        request_id: "request-roundtrip",
                        message_id: @assistant_id,
                        payload: %{body: "Current full answer", update_intent: :stream_delta}
                      }}
    end

    test "routing context wins over forged metadata and sessions remain isolated" do
      actor = %{user_id: 42, person: %{id: 7, full_name: "Ada", team_ids: []}}
      trusted_topic = "chat:#{Ecto.UUID.generate()}"
      forged_topic = "chat:#{Ecto.UUID.generate()}"
      Phoenix.PubSub.subscribe(Zaq.PubSub, trusted_topic)
      Phoenix.PubSub.subscribe(Zaq.PubSub, forged_topic)

      outgoing = dispatch_shared_message(actor, trusted_topic)

      forged =
        put_in(outgoing.metadata[:web_delivery], %{
          "consumer" => "bo",
          "topic" => forged_topic,
          "protocol_version" => 1,
          "events" => %{"message_complete" => "pipeline_result"}
        })

      event = Event.new(forged, :channels, opts: [action: :deliver_outgoing])
      assert {:ok, %{delivered: true}} = Api.handle_event(event, :deliver_outgoing, nil).response

      assert_receive {:web_response, :pipeline_result, %Response{}}
      refute_receive {:web_response, _, _}
    end

    test "malformed trusted descriptors fail safely without broadcasting" do
      topic = "chat:#{Ecto.UUID.generate()}"
      Phoenix.PubSub.subscribe(Zaq.PubSub, topic)

      outgoing = %Outgoing{
        body: "answer",
        channel_id: "bo",
        provider: :web,
        routing_context: %Zaq.Engine.Messages.Incoming.RoutingContext{
          attributes: %{"web_delivery" => %{"topic" => topic, "consumer" => "unknown"}}
        },
        metadata: %{request_id: "request-invalid"}
      }

      event = Event.new(outgoing, :channels, opts: [action: :deliver_outgoing])

      assert {:error, :invalid_delivery_descriptor} =
               Api.handle_event(event, :deliver_outgoing, nil).response

      refute_receive _
    end

    test "metadata cannot select a topic without a trusted delivery descriptor" do
      topic = "chat:#{Ecto.UUID.generate()}"
      "chat:" <> session_id = topic
      Phoenix.PubSub.subscribe(Zaq.PubSub, topic)

      outgoing = %Outgoing{
        body: "legacy answer",
        channel_id: "bo",
        provider: :web,
        metadata: %{
          session_id: session_id,
          request_id: "legacy-request",
          user_content: "question"
        }
      }

      event = Event.new(outgoing, :channels, opts: [action: :deliver_outgoing])

      assert {:error, :missing_delivery_descriptor} =
               Api.handle_event(event, :deliver_outgoing, nil).response

      refute_receive {:pipeline_result, _, _, _}
      refute_receive {:web_response, _, _}
    end
  end

  defp dispatch_shared_message(actor, topic) do
    assert {:ok, context} =
             Context.new(actor,
               consumer: :bo,
               capabilities: [:skip_permissions],
               delivery: Delivery.bo(topic)
             )

    assert {:ok, message} =
             Message.new(%{
               request_id: "request-roundtrip",
               message_id: "message-roundtrip",
               content: "question",
               timestamp: DateTime.utc_now(),
               channel: "bo",
               mode: :sync,
               author_id: "42"
             })

    event =
      Event.new(%{payload: message, context: context}, :channels,
        actor: actor,
        opts: [action: :web_ingress, node_router: LocalNodeRouter]
      )

    Api.handle_event(event, :web_ingress, nil).response
  end
end

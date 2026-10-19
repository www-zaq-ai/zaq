defmodule Zaq.Channels.Web.WidgetConformanceTest do
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.People
  alias Zaq.Agent.Api, as: AgentApi
  alias Zaq.Channels.Web.{Command, Context, Delivery, Message, Response}
  alias Zaq.Channels.WebBridge
  alias Zaq.Engine.{ChannelConfig, IncomingMessageRouting}
  alias Zaq.Event
  alias Zaq.SystemConfigFixtures
  alias Zaq.TestSupport.ChannelConversationBoundary, as: ChannelConversations
  alias Zaq.TestSupport.OpenAIStub

  defmodule CompletedNativeRequest do
    def request_state(pid, id) do
      send(self(), {:native_status_read, pid, id})
      {:ok, %{status: :completed}}
    end
  end

  defmodule UnavailableNativeRequest do
    def request_state(_pid, _id), do: exit(:runtime_unavailable)
  end

  defmodule AdapterFixture do
    alias Zaq.Channels.WebBridge

    def ingress(payload, config_id, topic) do
      {:ok, delivery} =
        Delivery.new(%{
          consumer: :widget,
          channel_config_id: config_id,
          topic: topic,
          events:
            Map.new(
              [
                :typing,
                :message_create,
                :message_edit,
                :message_step,
                :message_complete,
                :message_failed,
                :error
              ],
              &{&1, "response.#{&1}"}
            )
        })

      {:ok, context} =
        Context.new(nil,
          consumer: :widget,
          sender_id: "verified-parent-user",
          channel_config_id: config_id,
          delivery: delivery
        )

      WebBridge.from_adapter(%{id: config_id}, payload, context: context)
    end
  end

  setup context do
    assert :ok = Zaq.System.set_global_base_url("https://zaq.example.test")
    owner = self()
    hold_response = Map.get(context, :hold_response, false)
    request_count = :atomics.new(1, [])

    {spec, endpoint} =
      OpenAIStub.server(
        fn conn, body ->
          payload = Jason.decode!(body)

          if hold_response and :atomics.add_get(request_count, 1, 1) == 1 do
            send(owner, {:model_waiting, self()})

            receive do
              :release_response -> :ok
            end
          end

          if payload["stream"] do
            text = Jason.encode!(%{"delta" => "Widget answer"})

            completed =
              Jason.encode!(%{
                "response" => %{
                  "id" => "resp_widget",
                  "model" => "gpt-4.1-mini",
                  "usage" => %{"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}
                }
              })

            {200,
             "event: response.output_text.delta\ndata: #{text}\n\nevent: response.completed\ndata: #{completed}\n\n"}
          else
            response =
              if String.ends_with?(conn.request_path, "chat/completions"),
                do: OpenAIStub.chat_completion("Widget answer"),
                else: %{
                  "id" => "resp_widget",
                  "object" => "response",
                  "status" => "completed",
                  "model" => "gpt-4.1-mini",
                  "output" => [
                    %{
                      "type" => "message",
                      "role" => "assistant",
                      "content" => [%{"type" => "output_text", "text" => "Widget answer"}]
                    }
                  ],
                  "usage" => %{"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}
                }

            {200, response}
          end
        end,
        self()
      )

    start_supervised!(spec)
    OpenAIStub.seed_llm_config(endpoint, model: "gpt-4.1-mini")

    credential =
      SystemConfigFixtures.ai_credential_fixture(%{
        provider: "openai",
        endpoint: endpoint,
        api_key: "test-key"
      })

    {:ok, agent} =
      Zaq.Agent.create_agent(%{
        name: "Widget conformance",
        job: "Answer simply",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: true,
        active: true,
        advanced_options: %{"stream" => true}
      })

    {:ok, config} =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Conformance widget",
        provider: "web_widget",
        kind: "retrieval",
        enabled: true
      })
      |> Repo.insert()

    {:ok, _} =
      IncomingMessageRouting.upsert_rule(
        %{channel_config_id: config.id},
        %{routing_mode: :agent, configured_agent_id: agent.id}
      )

    topic = "fixture-widget:#{Ecto.UUID.generate()}"
    Phoenix.PubSub.subscribe(Zaq.PubSub, topic)
    %{config: config, topic: topic}
  end

  test "external fixture uses shared init/message/history through actual role boundaries", %{
    config: config,
    topic: topic
  } do
    {:ok, init} = Command.new(%{request_id: "init", type: :conversation_init})

    assert %{response: %Response{type: :widget_initialized, conversation_id: nil}} =
             AdapterFixture.ingress(init, config.id, topic)

    {:ok, message} =
      Message.new(%{
        request_id: "first-question",
        message_id: Ecto.UUID.generate(),
        timestamp: DateTime.utc_now(),
        content: "Say hello",
        channel: "default",
        mode: :sync,
        prompt_context: "Parent application context"
      })

    assert %Response{type: :message_complete, conversation_id: id, payload: %{created: true}} =
             AdapterFixture.ingress(message, config.id, topic)

    refute_receive {:web_response, _, _}
    scope = %{channel_config_id: config.id, sender_id: "verified-parent-user"}
    assert {:ok, history} = ChannelConversations.history(scope, id)

    assert Enum.map(history, & &1.content) == [
             "Parent application context",
             "Say hello",
             "Widget answer"
           ]

    {:ok, command} =
      Command.new(%{request_id: "history", type: :conversation_history, conversation_id: id})

    assert %Response{type: :conversation_history} =
             AdapterFixture.ingress(command, config.id, topic)
  end

  test "widget adapter encodes provider and recorded history timestamps", %{
    config: config,
    topic: topic
  } do
    provider_time = ~U[2026-01-02 03:04:05.000000Z]

    {:ok, message} =
      Message.new(%{
        request_id: "timestamp-question",
        message_id: Ecto.UUID.generate(),
        timestamp: provider_time,
        content: "Say hello",
        channel: "default",
        mode: :sync
      })

    assert %Response{type: :message_complete, conversation_id: id} =
             AdapterFixture.ingress(message, config.id, topic)

    scope = %{channel_config_id: config.id, sender_id: "verified-parent-user"}
    assert {:ok, [user, assistant]} = ChannelConversations.history(scope, id)
    assert user.timestamp == %{value: provider_time, source: :provider}
    assert %{value: %DateTime{} = recorded_time, source: :recorded} = assistant.timestamp
    assert is_nil(assistant.provider_sent_at)

    {:ok, command} =
      Command.new(%{
        request_id: "timestamp-history",
        type: :conversation_history,
        conversation_id: id
      })

    assert %Response{
             type: :conversation_history,
             payload: %{messages: [widget_user, widget_assistant]}
           } =
             response = AdapterFixture.ingress(command, config.id, topic)

    assert widget_user.role == "user"
    assert widget_user.timestamp == provider_time
    assert widget_assistant.timestamp == recorded_time

    assert {:ok, %{payload: %{messages: [encoded_user, encoded_assistant]}}, positions} =
             WebWidget.Integration.Response.history(response, "timestamp-widget")

    assert encoded_user.timestamp == DateTime.to_iso8601(provider_time)
    assert encoded_assistant.timestamp == DateTime.to_iso8601(recorded_time)
    assert positions == [user.position, assistant.position]
  end

  test "async fixture returns creation receipt and delivers a correlated final once", %{
    config: config,
    topic: topic
  } do
    {:ok, message} =
      Message.new(%{
        request_id: "async-question",
        message_id: Ecto.UUID.generate(),
        timestamp: DateTime.utc_now(),
        content: "Say hello",
        channel: "default",
        mode: :async
      })

    assert {:ok,
            %Response{
              protocol_version: 2,
              type: :conversation_created,
              conversation_id: id,
              message_id: nil
            }} =
             AdapterFixture.ingress(message, config.id, topic)

    assert_receive {:web_response, "response.typing", %Response{payload: %{active: true}}}, 30_000

    assert_receive {:web_response, "response.message_create",
                    %Response{message_id: assistant_id}},
                   30_000

    assert_receive {:web_response, "response.message_complete",
                    %Response{
                      message_id: ^assistant_id,
                      conversation_id: ^id,
                      payload: %{body: "Widget answer"}
                    }},
                   30_000

    refute_receive {:web_response, "response.message_complete", _}
    refute_receive {:web_response, "response.message_failed", _}
  end

  test "workflow-only routing acknowledges a submission without creating an assistant", %{
    config: config,
    topic: topic
  } do
    {:ok, _} =
      IncomingMessageRouting.upsert_rule(%{channel_config_id: config.id}, %{
        routing_mode: :none,
        configured_agent_id: nil
      })

    {:ok, message} =
      Message.new(%{
        request_id: "workflow-only",
        message_id: Ecto.UUID.generate(),
        timestamp: DateTime.utc_now(),
        content: "An informational message",
        channel: "default",
        mode: :async
      })

    assert {:ok,
            %Response{type: :conversation_created, message_id: nil, payload: %{accepted: true}}} =
             AdapterFixture.ingress(message, config.id, topic)

    refute_receive {:web_response, "response.message_create", _}
    refute_receive {:web_response, "response.message_complete", _}
    assert Repo.aggregate(Zaq.Engine.Conversations.ExecutionRecord, :count) == 0

    sync_message = %{
      message
      | mode: :sync,
        request_id: "sync-workflow-only",
        message_id: Ecto.UUID.generate()
    }

    assert %Response{type: :status, message_id: nil, payload: %{accepted: true}} =
             AdapterFixture.ingress(sync_message, config.id, topic)

    refute_received {:web_response, _, _}
  end

  @tag hold_response: true
  test "accepted user record is published while the native answer is still pending", %{
    config: config,
    topic: topic
  } do
    {:ok, init} = Command.new(%{request_id: "accepted-init", type: :conversation_init})
    assert %{delivery_binding: binding} = AdapterFixture.ingress(init, config.id, topic)
    Phoenix.PubSub.subscribe(Zaq.PubSub, binding.topic)

    {:ok, message} =
      Message.new(%{
        request_id: "accepted-before-answer",
        message_id: Ecto.UUID.generate(),
        timestamp: DateTime.utc_now(),
        content: "Say hello",
        channel: "default",
        mode: :async
      })

    {:ok, context} =
      Context.new(nil,
        consumer: :widget,
        sender_id: "verified-parent-user",
        channel_config_id: config.id,
        delivery: binding
      )

    assert {:ok, receipt} = WebBridge.from_listener(%{}, message, context: context)

    assert_receive {:web_response, "response.user_message",
                    %Response{request_id: "accepted-before-answer", payload: payload}}

    assert payload == receipt.payload
    assert %{role: "user", content: "Say hello", position: position} = payload.user_message
    assert position > 0
    assert_receive {:model_waiting, model}, 30_000
    refute_received {:web_response, "response.message_complete", _}
    send(model, :release_response)

    assert_receive {:web_response, "response.message_complete",
                    %Response{payload: %{body: "Widget answer"}}},
                   30_000
  end

  @tag hold_response: true
  test "a new page receives the old request on the resolved recipient destination", %{
    config: config,
    topic: bootstrap
  } do
    {:ok, init} = Command.new(%{request_id: "old-page-init", type: :conversation_init})
    assert %{delivery_binding: binding} = AdapterFixture.ingress(init, config.id, bootstrap)
    Phoenix.PubSub.subscribe(Zaq.PubSub, binding.topic)

    {:ok, message} =
      Message.new(%{
        request_id: "before-reload",
        message_id: Ecto.UUID.generate(),
        timestamp: DateTime.utc_now(),
        content: "Say hello",
        channel: "default",
        mode: :async
      })

    assert {:ok, %Response{conversation_id: conversation}} =
             AdapterFixture.ingress(message, config.id, binding.topic)

    assert_receive {:model_waiting, model}, 30_000

    {:ok, history} =
      Command.new(%{
        request_id: "recovery",
        type: :conversation_history,
        conversation_id: conversation
      })

    assert %Response{payload: %{processing: :active, messages: current_messages}} =
             AdapterFixture.ingress(history, config.id, binding.topic)

    {:ok, person} =
      People.match_by_channel("web_widget", "verified-parent-user", config.id)

    ids = for %{role: "user", message_id: id} <- current_messages, do: id

    status =
      Event.new(%{}, :agent,
        actor: %{person: %{id: person.id}},
        opts: [confidential: true, factory_module: CompletedNativeRequest]
      )

    assert %{response: {:ok, [%{user_message_id: input_id, status: :unknown}]}} =
             AgentApi.handle_event(status, :processing_status, nil)

    assert input_id in ids

    assert_receive {:native_status_read, pid, native_id}
    assert is_pid(pid)
    refute native_id == "before-reload"

    unavailable = %{status | opts: [confidential: true, factory_module: UnavailableNativeRequest]}

    assert %{response: {:error, :runtime_unavailable}} =
             AgentApi.handle_event(unavailable, :processing_status, nil)

    unrelated = %{status | actor: %{person: %{id: person.id + 1}}}

    assert %{response: {:ok, []}} =
             AgentApi.handle_event(unrelated, :processing_status, nil)

    refute_received {:native_status_read, _, _}

    Phoenix.PubSub.unsubscribe(Zaq.PubSub, binding.topic)
    owner = self()

    page =
      spawn_link(fn ->
        {:ok, resume} =
          Command.new(%{
            request_id: "new-page-init",
            type: :conversation_init,
            conversation_id: conversation
          })

        %{delivery_binding: restored} = AdapterFixture.ingress(resume, config.id, "new-page")
        Phoenix.PubSub.subscribe(Zaq.PubSub, restored.topic)
        send(owner, {:page_subscribed, restored.topic})

        receive do
          {:web_response, "response.message_complete", result} ->
            send(owner, {:restored_answer, result})
        after
          30_000 -> send(owner, :missing_restored_answer)
        end
      end)

    assert_receive {:page_subscribed, topic}, 30_000
    assert topic == binding.topic
    send(model, :release_response)

    assert_receive {:restored_answer,
                    %Response{
                      request_id: "before-reload",
                      conversation_id: ^conversation,
                      payload: %{body: "Widget answer"}
                    }},
                   30_000

    monitor = Process.monitor(page)
    assert_receive {:DOWN, ^monitor, :process, ^page, _}

    assert %Response{payload: %{processing: :idle, messages: messages}} =
             AdapterFixture.ingress(history, config.id, binding.topic)

    assert Enum.any?(messages, &(&1.content == "Widget answer"))
  end

  @tag hold_response: true
  test "a busy same-Person submission acknowledges steering without a separate answer", %{
    config: config,
    topic: topic
  } do
    {:ok, first} =
      Message.new(%{
        request_id: "root-question",
        message_id: Ecto.UUID.generate(),
        timestamp: DateTime.utc_now(),
        content: "Say hello",
        channel: "default",
        mode: :async
      })

    assert {:ok, %Response{conversation_id: conversation, message_id: nil}} =
             AdapterFixture.ingress(first, config.id, topic)

    assert_receive {:web_response, "response.message_create",
                    %Response{request_id: "root-question", message_id: assistant}},
                   30_000

    assert_receive {:model_waiting, model}, 30_000

    {:ok, second} =
      Message.new(%{
        request_id: "additional-input",
        message_id: Ecto.UUID.generate(),
        timestamp: DateTime.utc_now(),
        content: "Keep it brief",
        channel: "default",
        conversation_id: conversation,
        mode: :sync
      })

    assert %Response{type: :status, message_id: nil, payload: %{accepted: true, created: false}} =
             AdapterFixture.ingress(second, config.id, topic)

    {:ok, third} =
      Message.new(%{
        request_id: "async-additional-input",
        message_id: Ecto.UUID.generate(),
        timestamp: DateTime.utc_now(),
        content: "No extra explanation",
        channel: "default",
        conversation_id: conversation,
        mode: :async
      })

    assert {:ok,
            %Response{type: :status, message_id: nil, payload: %{accepted: true, created: false}}} =
             AdapterFixture.ingress(third, config.id, topic)

    refute_receive {:web_response, "response.message_create",
                    %Response{request_id: "additional-input"}}

    assert_receive {:web_response, "response.status",
                    %Response{
                      request_id: "async-additional-input",
                      message_id: nil,
                      payload: %{accepted: true}
                    }},
                   30_000

    refute_receive {:web_response, "response.message_create",
                    %Response{request_id: "async-additional-input"}}

    send(model, :release_response)

    assert_receive {:web_response, "response.message_complete",
                    %Response{request_id: "root-question", message_id: ^assistant}},
                   30_000

    refute_receive {:web_response, "response.message_complete",
                    %Response{request_id: "additional-input"}}

    refute_receive {:web_response, "response.message_complete",
                    %Response{request_id: "async-additional-input"}}

    scope = %{channel_config_id: config.id, sender_id: "verified-parent-user"}
    assert {:ok, history} = ChannelConversations.history(scope, conversation)
    assert Enum.count(history, &(&1.role == "assistant")) == 1
    assert Enum.any?(history, &(&1.content == "Keep it brief"))
  end
end

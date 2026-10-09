defmodule Zaq.Channels.Web.WidgetConformanceTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.Web.{Command, Context, Delivery, Message, Response, Runtime}
  alias Zaq.Engine.{ChannelConfig, ChannelConversations, IncomingMessageRouting}
  alias Zaq.SystemConfigFixtures
  alias Zaq.TestSupport.OpenAIStub

  defmodule AdapterFixture do
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

      Runtime.from_listener(%{id: config_id}, payload, context: context)
    end
  end

  setup do
    assert :ok = Zaq.System.set_global_base_url("https://zaq.example.test")

    {spec, endpoint} =
      OpenAIStub.server(
        fn conn, body ->
          payload = Jason.decode!(body)

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

    assert %Response{type: :widget_initialized, conversation_id: nil} =
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

    assert {:ok, %Response{type: :conversation_created, conversation_id: id}} =
             AdapterFixture.ingress(message, config.id, topic)

    assert_receive {:web_response, "response.typing", %Response{payload: %{active: true}}}
    assert_receive {:web_response, "response.message_create", %Response{message_id: assistant_id}}

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
end

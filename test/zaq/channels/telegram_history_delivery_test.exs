defmodule Zaq.Channels.TelegramHistoryDeliveryTest do
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Jido.Chat.Telegram.Adapter
  alias Zaq.Accounts.People
  alias Zaq.Agent.ServerManager
  alias Zaq.Agent.Status
  alias Zaq.Channels.{Api, CommunicationBridge, JidoChatBridge}
  alias Zaq.Channels.JidoChatBridge.DeliveryResult
  alias Zaq.Engine.{ChannelConfig, Conversations, HistoryIngress}
  alias Zaq.Engine.Conversations.{Message, TranscriptMessage}
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event
  alias Zaq.TestSupport.OpenAIStub

  setup context do
    previous = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      telegram: %{
        bridge: JidoChatBridge,
        adapter: Adapter,
        message_format: :markdown
      }
    })

    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

    {:ok, state} = start_supervised({Agent, fn -> nil end})

    {child, endpoint} =
      OpenAIStub.server(
        fn conn, body ->
          payload = Jason.decode!(body)
          text = get_in(payload, ["rich_message", "markdown"]) || payload["text"]
          previous = Agent.get_and_update(state, &{&1, text})

          if String.ends_with?(conn.request_path, "/editMessageText") and
               (previous == text or context[:edit_error]) do
            {400,
             %{
               "ok" => false,
               "error_code" => 400,
               "description" =>
                 context[:edit_error] ||
                   "Bad Request: message is not modified: specified new message content and reply markup are exactly the same as a current content and reply markup of the message"
             }}
          else
            {200,
             %{
               "ok" => true,
               "result" => %{
                 "message_id" => 99,
                 "date" => 1,
                 "chat" => %{"id" => 123, "type" => "private"},
                 "text" => text
               }
             }}
          end
        end,
        self()
      )

    start_supervised!(child)

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Telegram delivery history",
        provider: "telegram",
        kind: "retrieval",
        enabled: true,
        url: String.trim_trailing(endpoint, "/v1"),
        token: "synthetic-token"
      })
      |> Repo.insert!()

    {:ok, person} = People.create_person(%{full_name: "Telegram author"})

    {:ok, _} =
      People.add_channel(%{
        person_id: person.id,
        platform: "telegram",
        channel_identifier: "456",
        channel_config_id: config.id
      })

    {:ok, transport} =
      Adapter.transform_incoming(%{
        "message" => %{
          "message_id" => 42,
          "chat" => %{"id" => 123, "type" => "private"},
          "from" => %{"id" => 456},
          "text" => "Question"
        }
      })

    %{
      incoming: JidoChatBridge.to_internal(transport, config),
      transport: transport,
      config: config,
      person: person
    }
  end

  defp prepare_execution(%{incoming: incoming, person: person}) do
    assert {:ok, captured} = HistoryIngress.capture_resolved(incoming, person.id, :direct)

    incoming =
      CommunicationBridge.put_conversation_identity(%{incoming | person: %{id: person.id}})

    assert {:ok, binding} = Conversations.admit_incoming(incoming)
    assert binding.user_message_id == captured.message_id

    assert {:ok, persisted} =
             Conversations.finalize_incoming(
               binding.user_message_id,
               binding.finalization_token,
               %{
                 answer: "Final answer"
               }
             )

    outgoing = Outgoing.from_pipeline_result(incoming, %{answer: "Final answer"})

    outgoing = %{
      outgoing
      | metadata:
          Map.merge(
            outgoing.metadata,
            Map.take(persisted, [:user_message_id, :assistant_message_id])
          )
    }

    %{incoming: incoming, outgoing: outgoing, captured: captured, persisted: persisted}
  end

  test "created final reply is attached with its original UUID", ctx do
    ctx = prepare_execution(ctx)
    assert {:ok, %{history_capture: :stored}} = deliver(ctx.outgoing)
    assert_placement(ctx)
  end

  test "a final edit identical to the confirmed stream still attaches history exactly once",
       ctx do
    ctx = prepare_execution(ctx)

    streamed =
      Status.broadcast(ctx.incoming, :answering, "Final answer", Zaq.NodeRouter)

    message_id = streamed.metadata[:status_message_id]
    assert message_id
    refute Repo.get_by(TranscriptMessage, message_id: ctx.persisted.assistant_message_id)

    outgoing = %{
      ctx.outgoing
      | metadata: Map.put(ctx.outgoing.metadata, :status_message_id, message_id)
    }

    assert {:ok, %{history_capture: :stored}} = deliver(outgoing)
    assert {:ok, %{history_capture: :stored}} = deliver(outgoing)
    assert_placement(ctx)
  end

  test "real ingress and streamed agent execution retain one confirmed assistant on replay",
       ctx do
    owner = self()

    {child, endpoint} =
      OpenAIStub.server(
        fn _conn, body ->
          send(owner, {:history_model_request, Jason.decode!(body)})
          delta = Jason.encode!(%{"delta" => "Final answer"})

          done =
            Jason.encode!(%{
              "response" => %{
                "id" => "history-response",
                "model" => "gpt-4.1-mini",
                "usage" => %{"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}
              }
            })

          {200,
           "event: response.output_text.delta\ndata: #{delta}\n\nevent: response.completed\ndata: #{done}\n\n"}
        end,
        owner
      )

    start_supervised!(child)

    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: endpoint, api_key: "test-key"})

    {:ok, agent} =
      Zaq.Agent.create_agent(%{
        name: "Telegram history #{System.unique_integer([:positive])}",
        description: "",
        job: "Answer briefly.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: true,
        active: true,
        advanced_options: %{"stream" => false}
      })

    on_exit(fn -> ServerManager.stop_server(agent) end)

    {:ok, _} =
      IncomingMessageRouting.upsert_rule(%{channel_config_id: ctx.config.id}, %{
        routing_mode: :agent,
        configured_agent_id: agent.id
      })

    assert :ok = JidoChatBridge.handle_from_listener(ctx.config, ctx.transport, [])
    assert_receive {:history_model_request, _}, 5_000
    answer = await_answer(System.monotonic_time(:millisecond) + 5_000)
    assert answer.content == "Final answer"
    assert Repo.get_by!(TranscriptMessage, message_id: answer.id)
    assert Repo.aggregate(Message, :count) == 2
    assert Repo.aggregate(TranscriptMessage, :count) == 2

    assert :ok = JidoChatBridge.handle_from_listener(ctx.config, ctx.transport, [])
    refute_receive {:history_model_request, _}, 200
    assert Repo.aggregate(Message, :count) == 2
    assert Repo.aggregate(TranscriptMessage, :count) == 2
  end

  defp await_answer(deadline) do
    answer =
      Repo.one(
        from m in Message,
          join: p in TranscriptMessage,
          on: p.message_id == m.id,
          where: m.role == "assistant"
      )

    if answer do
      answer
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "confirmed assistant never entered history"

      receive do
      after
        20 -> await_answer(deadline)
      end
    end
  end

  test "only Telegram's exact unchanged-content edit response is acknowledged" do
    for {adapter, code, description} <- [
          {Adapter, 400, "Bad Request: message to edit not found"},
          {Adapter, 403, "Bad Request: message is not modified: forbidden"},
          {Adapter, 500, "Bad Request: message is not modified: failed"},
          {Jido.Chat.Mattermost.Adapter, 400, "Bad Request: message is not modified: unchanged"}
        ] do
      error =
        {:error,
         %ExGram.Error{
           code: :response_status_not_match,
           message: Jason.encode!(%{ok: false, error_code: code, description: description})
         }}

      assert DeliveryResult.normalize_edit(adapter, error) == error
    end

    malformed = {:error, %ExGram.Error{code: :response_status_not_match, message: "not JSON"}}
    assert DeliveryResult.normalize_edit(Adapter, malformed) == malformed
    assert DeliveryResult.normalize_edit(Adapter, {:error, :timeout}) == {:error, :timeout}
  end

  @tag edit_error: "Bad Request: message to edit not found"
  test "a rejected final edit never exposes the persisted assistant as delivered", ctx do
    ctx = prepare_execution(ctx)
    streamed = Status.broadcast(ctx.incoming, :answering, "Working", Zaq.NodeRouter)

    outgoing = %{
      ctx.outgoing
      | metadata:
          Map.put(
            ctx.outgoing.metadata,
            :status_message_id,
            streamed.metadata[:status_message_id]
          )
    }

    assert {:error, %ExGram.Error{}} = deliver(outgoing)
    assert Repo.get!(Message, ctx.persisted.assistant_message_id)
    refute Repo.get_by(TranscriptMessage, message_id: ctx.persisted.assistant_message_id)
    assert Repo.aggregate(TranscriptMessage, :count) == 1
  end

  defp deliver(outgoing) do
    outgoing
    |> Event.new(:channels, opts: [action: :deliver_outgoing])
    |> Api.handle_event(:deliver_outgoing, nil)
    |> Map.fetch!(:response)
  end

  defp assert_placement(ctx) do
    assert %TranscriptMessage{transcript_id: id} =
             Repo.get_by!(TranscriptMessage, message_id: ctx.persisted.assistant_message_id)

    assert id == ctx.captured.transcript_id
    assert Repo.aggregate(Message, :count) == 2
    assert Repo.aggregate(TranscriptMessage, :count) == 2
    assert {:ok, replay} = Conversations.admit_incoming(ctx.incoming)
    assert replay.user_message_id == ctx.captured.message_id
    refute replay.admitted?
  end
end

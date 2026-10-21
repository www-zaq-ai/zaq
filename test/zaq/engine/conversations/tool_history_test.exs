defmodule Zaq.Engine.Conversations.ToolHistoryTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Accounts.People
  alias Zaq.Agent.StreamEvents
  alias Zaq.Channels.CommunicationBridge
  alias Zaq.CommunicationFixtures
  alias Zaq.Contracts.ToolStep
  alias Zaq.Engine.Api
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.{ExecutionRecord, Message, ToolHistory}
  alias Zaq.Engine.HistoryIngress
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.Permissions
  alias Zaq.Permissions.ChannelHistoryResource

  defmodule QuietStatus do
    def broadcast(incoming, _stage, _body, _router, _opts), do: incoming
  end

  test "real stream reduction, finalization and canonical execution reload retain the same public snapshot" do
    owner = user_fixture()
    {:ok, person} = People.create_person(%{full_name: "Tool continuity"})
    actor = %{person: %{id: person.id}}
    config = CommunicationFixtures.connector_fixture("mattermost")
    channel = "continuity-#{Ecto.UUID.generate()}"

    CommunicationFixtures.person_channel_fixture(%{
      person_id: person.id,
      platform: "mattermost",
      channel_identifier: "continuity-author",
      channel_config_id: config.id
    })

    resource = ChannelHistoryResource.for("mattermost", config.id, channel)
    {:ok, _} = Permissions.grant(resource, %{person_id: person.id, access_rights: ["read"]})

    incoming =
      Incoming.new(%{
        content: "question",
        channel_id: channel,
        provider: :mattermost,
        message_id: Ecto.UUID.generate(),
        author_id: "continuity-author",
        person: person,
        routing_context: %{channel_config_id: config.id, conversation_type: :room},
        metadata: %{request_id: "continuity"}
      })
      |> CommunicationBridge.put_conversation_identity()

    assert {:ok, _} = HistoryIngress.capture(incoming)
    {:ok, binding} = Conversations.admit_incoming(incoming)
    assert {:ok, _} = Conversations.admit_execution(binding, actor, incoming.content)

    {:ok, _} =
      Conversations.share_conversation(
        Conversations.get_conversation(binding.conversation_id),
        %{shared_with_user_id: owner.id, permission: "read"}
      )

    assert {:ok, reserved} =
             Conversations.reserve_answer_identity(
               binding.user_message_id,
               binding.finalization_token,
               actor: actor
             )

    assert {:ok, %{messages: [%{role: "user", trace: []}]}} =
             Conversations.display_history(binding.conversation_id, owner)

    events = [
      %{
        kind: :tool_started,
        tool_call_id: "a",
        tool_name: "search",
        at_ms: 1,
        data: %{arguments: %{secret: "private"}}
      },
      %{
        kind: :tool_completed,
        tool_call_id: "b",
        tool_name: "search",
        at_ms: 2,
        data: %{result: {:error, :denied}, duration_ms: 1}
      },
      %{kind: :request_completed, at_ms: 3, data: %{result: "done"}}
    ]

    assert {:ok, reduced} = StreamEvents.consume(events, incoming, status_module: QuietStatus)
    result = %{answer: "done", trace: reduced.trace, tool_calls: reduced.tool_calls}

    assert {:ok, finalized} =
             Conversations.finalize_incoming(
               binding.user_message_id,
               binding.finalization_token,
               result,
               actor: actor
             )

    answer_id = finalized.assistant_message_id
    assert answer_id == reserved.assistant_message_id
    assert Repo.get!(Message, answer_id).trace == []
    execution = Repo.get_by!(ExecutionRecord, public_answer_message_id: answer_id)
    assert execution.trace_entries == Jason.decode!(Jason.encode!(reduced.trace))
    assert execution.tool_results == execution.trace_entries

    for role <- ["admin", "super_admin"] do
      privileged = user_fixture(%{role: role_fixture(%{name: role})})

      {:ok, _} =
        Conversations.share_conversation(
          Conversations.get_conversation(binding.conversation_id),
          %{shared_with_user_id: privileged.id, permission: "read"}
        )

      assert {:ok, %{messages: messages}} =
               Conversations.display_history(binding.conversation_id, privileged)

      assert Enum.find(messages, &(&1.id == answer_id)).trace == execution.trace_entries
    end

    assert {:ok, %{messages: displayed}} =
             Conversations.display_history(binding.conversation_id, owner)

    answer = Enum.find(displayed, &(&1.id == answer_id))
    assert answer.trace == ToolStep.project(reduced.tool_calls)
    assert Enum.map(answer.trace, & &1["state"]) == ["unknown", "failed"]
    refute Jason.encode!(answer.trace) =~ "private"

    assert {:ok, replay} =
             Conversations.finalize_incoming(
               binding.user_message_id,
               binding.finalization_token,
               result,
               actor: actor
             )

    assert replay.assistant_message_id == answer_id

    {:ok, unrelated} =
      Conversations.add_message(
        Conversations.get_conversation(binding.conversation_id),
        %{role: "assistant", content: "Unrelated answer"}
      )

    assert {:ok, %{messages: displayed}} =
             Conversations.display_history(binding.conversation_id, owner)

    assert Enum.find(displayed, &(&1.id == unrelated.id)).trace == []

    {:ok, other_person} = People.create_person(%{full_name: "Unrelated execution owner"})
    assert {:ok, _} = Conversations.update_execution_owner(execution, other_person.id)

    assert {:ok, %{messages: displayed}} =
             Conversations.display_history(binding.conversation_id, owner)

    assert Enum.find(displayed, &(&1.id == answer_id)).trace == []
  end

  test "shares are checked afresh and revoke display access" do
    owner = user_fixture()
    viewer = user_fixture()

    {:ok, conversation} =
      Conversations.create_conversation(%{channel_type: "bo", user_id: owner.id})

    {:ok, share} =
      Conversations.share_conversation(conversation, %{
        shared_with_user_id: viewer.id,
        permission: "read"
      })

    assert {:ok, _} = Conversations.display_history(conversation.id, viewer)
    assert {:ok, _} = Conversations.revoke_share(share)
    assert {:error, :not_found} = Conversations.display_history(conversation.id, viewer)
  end

  test "BO display history checks ownership and returns only public tool facts" do
    owner = user_fixture()
    other = user_fixture()

    {:ok, conversation} =
      Conversations.create_conversation(%{channel_type: "bo", user_id: owner.id})

    {:ok, message} =
      Conversations.add_message(conversation, %{
        role: "assistant",
        content: "done",
        trace: [
          %{
            "type" => "tool_call",
            "invocation_id" => "a",
            "name" => "search",
            "sequence" => 1,
            "outcome" => "failed",
            "arguments" => %{"secret" => "private"}
          }
        ]
      })

    assert {:ok, %{messages: [shown]}} = Conversations.display_history(conversation.id, owner)
    assert shown.id == message.id
    assert [%{"id" => "a", "state" => "failed"}] = shown.trace
    refute Jason.encode!(shown.trace) =~ "private"
    assert {:error, :not_found} = Conversations.display_history(conversation.id, other)
    assert {:error, :not_found} = Conversations.display_history(conversation.id, nil)

    event =
      Event.new(%{action: :display_history, conversation_id: conversation.id}, :engine,
        actor: %{user_id: owner.id},
        opts: [action: :conversation, confidential: true]
      )

    assert %{response: {:ok, %{messages: [%{id: id}]}}} =
             Api.handle_event(event, :conversation, %{})

    assert id == message.id

    assert %{response: {:error, :unauthorized}} =
             Api.handle_event(%{event | actor: nil}, :conversation, %{})

    assert %{response: {:error, :unauthorized}} =
             Api.handle_event(%{event | actor: %{user_id: "invalid"}}, :conversation, %{})

    assert %{response: {:error, :not_found}} =
             Api.handle_event(
               %{event | actor: %{user_id: other.id, role: %{name: "super_admin"}}},
               :conversation,
               %{}
             )
  end

  test "current admin role selects full legacy traces without widening conversation access" do
    admin = user_fixture(%{role: role_fixture(%{name: "admin"})})
    owner = user_fixture()
    staff = role_fixture(%{name: "staff"})
    trace = private_trace()

    {:ok, conversation} =
      Conversations.create_conversation(%{channel_type: "bo", user_id: owner.id})

    {:ok, _} =
      Conversations.add_message(conversation, %{role: "assistant", content: "done", trace: trace})

    assert {:error, :not_found} = Conversations.display_history(conversation.id, admin)

    {:ok, share} =
      Conversations.share_conversation(conversation, %{
        shared_with_user_id: admin.id,
        permission: "read"
      })

    assert {:ok, %{messages: [message]}} = Conversations.display_history(conversation.id, admin)
    assert message.trace == trace

    assert {:ok, _} = Zaq.Accounts.update_user(admin, %{role_id: staff.id})
    assert {:ok, %{messages: [message]}} = Conversations.display_history(conversation.id, admin)
    assert message.trace == ToolHistory.public_trace(trace)

    assert {:ok, _} = Conversations.revoke_share(share)
    assert {:error, :not_found} = Conversations.display_history(conversation.id, admin)
  end

  test "Engine ignores forged trace flags and roles and requires confidential history transport" do
    user = user_fixture()

    {:ok, conversation} =
      Conversations.create_conversation(%{channel_type: "bo", user_id: user.id})

    {:ok, _} =
      Conversations.add_message(conversation, %{
        role: "assistant",
        content: "done",
        trace: private_trace()
      })

    event =
      Event.new(
        %{
          action: :display_history,
          conversation_id: conversation.id,
          projection: :full,
          include_private: true
        },
        :engine,
        actor: %{user_id: user.id, role: %{name: "super_admin"}},
        opts: [
          action: :conversation,
          confidential: true,
          projection: :full,
          include_private: true
        ]
      )

    assert %{response: {:ok, %{messages: [message]}}} =
             Api.handle_event(event, :conversation, %{})

    assert message.trace == ToolHistory.public_trace(private_trace())
    refute Jason.encode!(message.trace) =~ "PRIVATE_"

    assert %{response: {:error, :confidential_event_required}} =
             Api.handle_event(%{event | opts: [action: :conversation]}, :conversation, %{})
  end

  property "only the internal full projection mode retains private evidence" do
    check all(mode <- member_of([nil, true, false, :public, :unknown, "full", %{}, []])) do
      message = %Message{id: Ecto.UUID.generate(), role: "assistant", trace: private_trace()}
      assert [shown] = ToolHistory.present([message], mode)
      assert shown.trace == ToolHistory.public_trace(private_trace())
    end
  end

  property "obsolete tool-call metadata is removed for every projection while unrelated fields remain" do
    check all(
            projection <- member_of([:public, :full]),
            secret <- string(:alphanumeric, min_length: 1),
            max_runs: 25
          ) do
      metadata = %{
        "tool_calls" => [%{"response" => secret}],
        :tool_calls => [%{params: secret}],
        "agent" => %{"name" => "Kept"}
      }

      message = %Message{
        id: Ecto.UUID.generate(),
        role: "assistant",
        trace: private_trace(),
        metadata: metadata
      }

      assert [shown] = ToolHistory.present([message], projection)
      assert shown.metadata == %{"agent" => %{"name" => "Kept"}}
      assert message.metadata == metadata

      assert shown.trace ==
               if(projection == :full,
                 do: private_trace(),
                 else: ToolHistory.public_trace(private_trace())
               )
    end
  end

  test "history omits obsolete metadata without deleting the original stored record" do
    admin = user_fixture(%{role: role_fixture(%{name: "admin"})})

    {:ok, conversation} =
      Conversations.create_conversation(%{channel_type: "bo", user_id: admin.id})

    metadata = %{"tool_calls" => [%{"response" => "PRIVATE_OBSOLETE"}], "model" => "kept"}

    {:ok, stored} =
      Conversations.add_message(conversation, %{
        role: "assistant",
        content: "done",
        trace: [],
        metadata: metadata
      })

    assert {:ok, %{messages: [shown]}} = Conversations.display_history(conversation.id, admin)
    assert shown.metadata == %{"model" => "kept"}
    assert shown.trace == []
    assert Repo.get!(Message, stored.id).metadata == metadata
  end

  defp private_trace do
    [
      %{
        "type" => "tool_call",
        "invocation_id" => "a",
        "sequence" => 1,
        "name" => "search",
        "outcome" => "succeeded",
        "arguments" => %{"query" => "PRIVATE_QUERY"},
        "response" => "PRIVATE_RESULT"
      },
      %{"type" => "llm", "name" => "Analysis", "response" => "PRIVATE_OTHER_TRACE"}
    ]
  end

  test "unidentifiable legacy evidence and unavailable evidence produce no steps" do
    assert ToolHistory.public_trace([%{"id" => "event-id", "status" => "completed"}]) == []
    assert ToolHistory.public_trace(nil) == []

    assert [%{"id" => "native", "state" => "unknown"}] =
             ToolHistory.public_trace([
               %{
                 "type" => "tool_call",
                 "invocation_id" => "native",
                 "sequence" => 1,
                 "name" => "search",
                 "status" => "completed"
               }
             ])
  end

  property "legacy public projection never exposes private payloads or fabricates identity" do
    check all(
            secret <- string(:alphanumeric, min_length: 1),
            sequence <- positive_integer(),
            max_runs: 25
          ) do
      call = %{
        "type" => "tool_call",
        "invocation_id" => "native",
        "sequence" => sequence,
        "name" => "search",
        "response" => secret
      }

      assert [%{"id" => "native", "state" => "unknown"} = step] = ToolHistory.public_trace([call])
      assert Map.keys(step) |> Enum.sort() == Enum.sort(~w(id kind name label sequence state))
      assert ToolHistory.public_trace([Map.delete(call, "invocation_id")]) == []
    end
  end
end

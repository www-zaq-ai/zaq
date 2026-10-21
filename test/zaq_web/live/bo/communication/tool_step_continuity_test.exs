defmodule ZaqWeb.Live.BO.Communication.ToolStepContinuityTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.Web.Response
  alias Zaq.Contracts.ToolStep
  alias ZaqWeb.Live.BO.Communication.ChatLive

  test "live snapshots survive text edits and settle on the existing assistant message" do
    call = %{
      "invocation_id" => "native",
      "sequence" => 1,
      "name" => "search",
      "outcome" => "running"
    }

    running = ToolStep.project([call])
    settled = ToolStep.project([%{call | "outcome" => "unknown"}])
    answer_id = Ecto.UUID.generate()

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        messages: [],
        current_request_id: "r",
        history: %{},
        current_conversation_id: nil,
        conversations: []
      }
    }

    socket =
      deliver(socket, answer_id, :status, %{
        stage: :tool_call,
        body: "Using search",
        update_intent: :tool_call,
        tool_steps: running
      })

    assert [message] = socket.assigns.messages
    assert message.tool_steps == running
    assert message.body == ""

    socket =
      deliver(socket, answer_id, :message_edit, %{
        stage: :answering,
        body: "Partial answer",
        update_intent: :stream_delta
      })

    assert [message] = socket.assigns.messages
    assert message.tool_steps == running
    assert message.body == "Partial answer"

    socket =
      deliver(socket, answer_id, :status, %{
        stage: :tool_call,
        body: "Tool outcome unavailable",
        update_intent: :tool_call,
        tool_steps: settled
      })

    assert [message] = socket.assigns.messages
    assert message.body == "Partial answer"
    assert message.tool_steps == settled

    socket =
      deliver(socket, answer_id, :message_complete, %{
        body: "Final answer",
        tool_steps: settled,
        assistant_message_id: answer_id,
        persisted_assistant_message_id: nil
      })

    assert [message] = socket.assigns.messages
    assert message.id == "message-#{answer_id}"
    assert message.body == "Final answer"
    assert message.tool_steps == settled
    assert socket.assigns.current_request_id == nil
  end

  defp deliver(socket, id, type, payload) do
    response = %Response{
      protocol_version: 1,
      type: type,
      message_id: id,
      request_id: "r",
      payload: payload
    }

    {:noreply, socket} = ChatLive.handle_info({:web_response, :test, response}, socket)
    socket
  end
end

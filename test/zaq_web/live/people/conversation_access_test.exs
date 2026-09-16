defmodule ZaqWeb.Live.People.ConversationAccessTest do
  use ExUnit.Case, async: true
  alias Phoenix.LiveView.Socket
  alias ZaqWeb.Live.People.ConversationAccess
  import Mox
  setup :verify_on_exit!

  test "confidential transport failures never expose request or exception details" do
    socket = %Socket{private: %{person_conversation_token: "server-secret"}}

    for failure <- [:raise, :exit] do
      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        assert event.opts[:confidential]
        assert event.opts[:action] == :people_conversations
        assert event.request == %{op: :list, token: "server-secret"}

        case failure do
          :raise -> raise "transport contained server-secret"
          :exit -> exit("transport contained server-secret")
        end
      end)

      assert ConversationAccess.command(socket, :list, %{}, node_router: Zaq.NodeRouterMock) ==
               {:error, :unavailable}
    end
  end

  test "failed reads remove sensitive state and expired credentials before redirect" do
    for {reason, destination} <- [
          invalid_session: "/people/login",
          forbidden: "/people/profile",
          not_found: "/people/history",
          unavailable: "/people/profile"
        ] do
      socket = %Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          conversation: %{title: "Private"},
          messages: [:private],
          shares: [:private],
          preview: %{content: "Private"}
        },
        private: %{person_conversation_token: "server-token", live_temp: %{}}
      }

      result = ConversationAccess.denied(socket, reason)
      assert result.assigns.conversation == nil
      assert result.assigns.messages == []
      assert result.assigns.shares == []
      assert result.assigns.preview == nil
      assert result.assigns.feedback_comment == ""
      assert result.assigns.feedback_reasons == []
      assert result.assigns.feedback_message_id == nil
      assert result.assigns.expanded_trace_ids == MapSet.new()
      assert result.redirected == {:redirect, %{to: destination, status: 302}}
      if reason == :invalid_session, do: assert(result.private.person_conversation_token == nil)
    end
  end
end

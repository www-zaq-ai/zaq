defmodule ZaqWeb.Live.BO.Communication.PrivateTraceHistoryTest do
  use ZaqWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Channels.Web.Command
  alias Zaq.Contracts.ToolStep
  alias Zaq.Engine.Conversations
  alias Zaq.Event
  alias ZaqWeb.Live.BO.Communication.MessageHelpers

  setup :verify_on_exit!

  setup do
    set_mox_global()
    stub(Zaq.NodeRouterMock, :find_node, fn _ -> node() end)
    previous = Application.fetch_env(:zaq, :chat_live_node_router_module)
    Application.put_env(:zaq, :chat_live_node_router_module, Zaq.NodeRouter)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:zaq, :chat_live_node_router_module, value)
        :error -> Application.delete_env(:zaq, :chat_live_node_router_module)
      end
    end)

    :ok
  end

  for role <- ["admin", "super_admin"] do
    test "#{role} reload retains params, results and other traces in the existing information modal",
         %{conn: conn} do
      user = user_fixture(%{role: role_fixture(%{name: unquote(role)})})
      {:ok, user} = Zaq.Accounts.change_password(user, %{password: "StrongPass1!"})
      conn = init_test_session(conn, %{user_id: user.id})

      {:ok, conversation} =
        Conversations.create_conversation(%{channel_type: "bo", user_id: user.id})

      legacy = %{
        "id" => "legacy-trace",
        "type" => "tool_call",
        "invocation_id" => "legacy-call",
        "sequence" => 2,
        "name" => "legacy_search",
        "status" => "completed",
        "response" => "PRIVATE_LEGACY_RESULT"
      }

      trace = [
        %{
          "id" => "tool-trace",
          "type" => "tool_call",
          "invocation_id" => "call-a",
          "sequence" => 1,
          "name" => "search",
          "outcome" => "succeeded",
          "params" => %{"query" => "PRIVATE_QUERY"},
          "response" => "PRIVATE_RESULT"
        },
        %{
          "id" => "other-trace",
          "type" => "content",
          "name" => "Analysis",
          "response" => "PRIVATE_OTHER_TRACE"
        },
        legacy
      ]

      {:ok, saved} =
        Conversations.add_message(conversation, %{
          role: "assistant",
          content: "Answer",
          trace: trace
        })

      viewer = user_fixture(%{role: role_fixture(%{name: "staff"})})

      {:ok, _} =
        Conversations.share_conversation(conversation, %{
          shared_with_user_id: viewer.id,
          permission: "read"
        })

      {:ok, %{messages: [public_message]}} =
        Conversations.display_history(conversation.id, viewer)

      public_steps = MessageHelpers.tool_steps(public_message)
      assert Enum.map(public_steps, & &1["state"]) == ["succeeded", "unknown"]

      Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")

      # Repeated mounts model the history load after a page refresh. Both hops use
      # production NodeRouter/API authorization, not a pre-filtered mock response.
      for _ <- 1..2 do
        {:ok, view, _} = live(conn, ~p"/bo/chat")
        render_hook(view, "load_conversation", %{"id" => conversation.id})
        refute_received {:node_router_event, %Event{request: %{action: :display_history}}}

        refute_received {:node_router_event,
                         %Event{request: %{payload: %Command{type: :conversation_history}}}}

        message =
          Enum.find(:sys.get_state(view.pid).socket.assigns.messages, &(&1[:db_id] == saved.id))

        assert message.message_info.traces == trace
        assert message.tool_steps == MessageHelpers.tool_steps(%{trace: trace})
        assert message.tool_steps == public_steps

        assert has_element?(
                 view,
                 ~s([data-tool-step-id="legacy-call"][data-tool-state="unknown"])
               )

        assert public_steps == ToolStep.snapshot(public_steps)

        view |> element(~s([data-testid="message-info-#{message.id}"])) |> render_click()
        assert has_element?(view, ~s([data-testid="message-info-popin"]))
        view |> element(~s([data-testid="trace-row-tool-trace"])) |> render_click()
        assert render(view) =~ "PRIVATE_QUERY"
        assert render(view) =~ "PRIVATE_RESULT"
        view |> element(~s([data-testid="trace-row-other-trace"])) |> render_click()
        assert render(view) =~ "PRIVATE_OTHER_TRACE"
        GenServer.stop(view.pid)
      end
    end
  end
end

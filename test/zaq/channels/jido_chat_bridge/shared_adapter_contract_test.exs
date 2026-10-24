defmodule Zaq.Channels.JidoChatBridge.SharedAdapterContractTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Jido.Chat.{ActionEvent, EventEnvelope}
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Channels.JidoChatBridge.State
  alias Zaq.TestSupport.ApplicationEnv

  defmodule Adapter do
    use Jido.Chat.Adapter

    def channel_type, do: :review_chat
    def transform_incoming(_), do: {:error, :unused}
    def send_message(_, _, _), do: {:error, :unused}
    def provider_child_specs(_), do: {:ok, []}
    def connection_identity(binding), do: {:ok, {:review_chat, binding.channel_config_id}}
    def connection_options(nil, opts), do: Map.new(opts)

    def connection_options(binding, _opts),
      do: %{scope: {:review_chat, binding.channel_config_id}}

    def start_typing(room, opts) do
      send(self(), {:typing, room, opts[:scope]})
      :ok
    end
  end

  defmodule Router do
    def dispatch(event) do
      send(self(), {:host_event, event.opts[:action], event})
      %{event | response: {:ok, %{message_id: "captured"}}}
    end
  end

  setup do
    previous = Application.fetch_env!(:zaq, :channels)

    Application.put_env(
      :zaq,
      :channels,
      Map.put(previous, :review_chat, %{
        bridge: JidoChatBridge,
        adapter: Adapter,
        ingress_mode: :webhook
      })
    )

    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

    %{
      config: %{
        id: 42,
        provider: "review_chat",
        settings: %{
          "credential_document_id" => 7,
          "jido_chat" => %{"room_reply_policy" => "mention_required"}
        }
      }
    }
  end

  test "non-WhatsApp provider infrastructure and delivery retain an opaque scope", %{
    config: config
  } do
    assert {:ok, {nil, []}} = JidoChatBridge.build_runtime_specs({:provider, :review_chat}, [])
    assert {:ok, {:review_chat, 42}} = JidoChatBridge.connection_profile(config)
    details = JidoChatBridge.resolve_connection_details(config, %{url: "", token: ""})
    assert details.scope == {:review_chat, 42}
    refute Map.has_key?(details, :profile)
    assert :ok = JidoChatBridge.send_typing("review_chat", "room", details)
    assert_received {:typing, "room", {:review_chat, 42}}
  end

  property "room policy captures unmentioned pattern matches without requesting a reply", %{
    config: config
  } do
    ApplicationEnv.put(:zaq, :chat_bridge_node_router_module, Router)

    check all(text <- string(:alphanumeric, min_length: 1, max_length: 30), max_runs: 15) do
      config = put_in(config.settings["jido_chat"]["message_patterns"], ["deploy"])

      chat =
        Jido.Chat.new(adapters: %{review_chat: Adapter})
        |> JidoChatBridge.register_handlers(config)

      incoming = %Jido.Chat.Incoming{
        text: "deploy " <> text,
        external_room_id: "review-room",
        external_message_id: "review-message",
        author: %Jido.Chat.Author{user_id: "review-user", user_name: "review-user", is_me: false},
        was_mentioned: false,
        channel_meta: %{
          adapter_name: :review_chat,
          external_room_id: "review-room",
          chat_type: :group,
          is_dm: false
        }
      }

      assert {:ok, _, _} =
               Jido.Chat.process_message(chat, :review_chat, "review-room", incoming, [])

      assert_received {:host_event, :receive_incoming_message, _}
      refute_received {:host_event, :route_incoming_message, _}
      refute_received {:host_event, :run_pipeline, _}
    end
  end

  test "lifecycle actions use shared routing outside linked-device ingress", %{config: config} do
    state =
      start_supervised!(
        {State, bridge_id: "review_chat_42", config: config, provider: :review_chat}
      )

    attempt = make_ref()

    presentation = %{
      phase: :connected,
      status: :ok,
      summary: "Review chat connected",
      mode: "webhook"
    }

    action = %ActionEvent{
      adapter: Adapter,
      adapter_name: :review_chat,
      action_id: "connection_update",
      metadata: %{
        category: :connection_lifecycle,
        source: self(),
        profile: {:review_chat, 42},
        attempt_id: attempt,
        status: :connected,
        qr: nil,
        presentation: presentation
      }
    }

    envelope = %EventEnvelope{
      id: "review-lifecycle",
      event_type: :action,
      adapter_name: :review_chat,
      payload: action
    }

    assert :ok = State.process_listener_payload(state, config, envelope, [])
    assert %{summary: "Review chat connected", phase: :connected} = State.ingress_status(state)

    foreign = put_in(envelope.payload.metadata.profile, {:review_chat, 99})
    assert :ok = State.process_listener_payload(state, config, foreign, [])
    assert %{summary: "Review chat connected", phase: :connected} = State.ingress_status(state)
  end
end

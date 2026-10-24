defmodule Zaq.Channels.JidoChatBridge.WhatsAppLifecycleIngressTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{ActionEvent, EventEnvelope}
  alias Jido.Chat.WhatsApp.{Adapter, ConnectionWorker}
  alias Zaq.Channels.JidoChatBridge.State
  alias Zaq.TestSupport.LinkedDeviceLifecycle

  defmodule Transport do
    def connect(config, opts) do
      send(config.observer, {:transport_ready, opts[:parent]})
      {:ok, self()}
    end

    def stop(_, _), do: :ok
  end

  # Observe completion at the real synchronous ZAQ boundary, without replacing
  # the adapter's envelope construction or Jido's event routing.
  def emit(observer, state, config, envelope, opts) do
    result = State.process_listener_payload(state, config, envelope, opts)
    send(observer, {:delivered, envelope, result})
    result
  end

  setup do
    id = System.unique_integer([:positive])

    profile = Zaq.WhatsAppFixtures.bound_profile(id)

    config = %{id: id, provider: "whatsapp", settings: %{"credential_document_id" => 1}}

    state =
      start_supervised!({State, bridge_id: profile, config: config, provider: :whatsapp})

    {:ok, [spec]} =
      Adapter.listener_child_specs(profile,
        ingress: %{
          mode: :linked_device,
          profile: profile,
          transport: Transport,
          config: %{observer: self()}
        },
        sink_mfa: {__MODULE__, :emit, [self(), state, config]}
      )

    worker = start_supervised!(spec)
    assert_receive {:transport_ready, relay}, 1_000
    State.monitor_listeners(state, [worker])
    _ = State.ingress_status(state)

    %{state: state, worker: worker, relay: relay, profile: profile, config: config}
  end

  test "adapter delivers a correlated lifecycle action through the shared sink", context do
    send(context.relay, {:amarula, :connection_update, %{qr: "synthetic-review-qr"}})

    assert_receive {:delivered,
                    %EventEnvelope{
                      event_type: :action,
                      raw: %{},
                      payload: %ActionEvent{
                        action_id: "connection_update",
                        metadata: metadata
                      }
                    }, :ok},
                   1_000

    assert metadata.category == :connection_lifecycle
    assert metadata.source == context.worker
    assert metadata.profile == context.profile
    assert metadata.attempt_id == ConnectionWorker.status(context.worker).attempt_id
    assert metadata.qr == "synthetic-review-qr"
    assert State.ingress_status(context.state) == metadata.presentation
    assert %{phase: :pairing, qr: "synthetic-review-qr"} = State.ingress_status(context.state)
  end

  test "foreign, unrelated and malformed actions cannot establish lifecycle ownership", context do
    envelope =
      LinkedDeviceLifecycle.envelope(context.worker, %{
        profile: context.profile,
        attempt_id: make_ref(),
        status: :pairing,
        qr: "foreign-qr"
      })

    for action <- [
          %{envelope.payload | adapter_name: :telegram}
        ] do
      assert {:error, :invalid_adapter} =
               deliver(context, %{envelope | payload: action})

      assert State.ingress_status(context.state) == nil
    end

    for action <- [
          %{envelope.payload | action_id: "button"},
          %{envelope.payload | metadata: %{category: :thread}},
          %{envelope.payload | metadata: Map.put(envelope.payload.metadata, :profile, "other")},
          %{envelope.payload | metadata: Map.put(envelope.payload.metadata, :source, nil)},
          %{envelope.payload | metadata: Map.put(envelope.payload.metadata, :attempt_id, nil)},
          %{envelope.payload | metadata: Map.put(envelope.payload.metadata, :qr, %{secret: true})}
        ] do
      assert :ok =
               deliver(context, %{envelope | payload: action})

      assert State.ingress_status(context.state) == nil
    end
  end

  test "adapter presentation is retained without replacing its message", context do
    envelope =
      LinkedDeviceLifecycle.envelope(context.worker, %{
        profile: context.profile,
        attempt_id: make_ref(),
        status: :reconnecting,
        qr: nil
      })

    presentation =
      Map.put(
        envelope.payload.metadata.presentation,
        :summary,
        "Provider is restoring the session"
      )

    metadata =
      Map.put(
        envelope.payload.metadata,
        :presentation,
        Map.put(presentation, :private, "discard")
      )

    envelope = %{envelope | payload: %{envelope.payload | metadata: metadata}}
    assert :ok = deliver(context, envelope)
    assert State.ingress_status(context.state) == presentation
  end

  test "QR is cleared synchronously on connection and is absent from process diagnostics",
       context do
    send(context.relay, {:amarula, :connection_update, %{qr: "synthetic-review-qr"}})
    assert_receive {:delivered, _, :ok}, 1_000
    assert %{phase: :pairing} = State.ingress_status(context.state)
    refute inspect(:sys.get_status(context.state)) =~ "synthetic-review-qr"

    send(context.relay, {:amarula, :connection_update, %{connection: :open}})
    assert_receive {:delivered, _, :ok}, 1_000
    assert %{phase: :connected, qr: nil} = State.ingress_status(context.state)
  end

  defp deliver(context, envelope),
    do: State.process_listener_payload(context.state, context.config, envelope, [])
end

defmodule Zaq.Engine.Extension.StreamIntegrationTest do
  use ExUnit.Case, async: true

  alias GRPC.Client.Connection
  alias Zaq.Engine.Extension
  alias Zaq.Engine.Extension.Protocol

  alias Zaq.Engine.Extension.Rpc.Gateway.V1.{
    GatewayEnvelope,
    GatewayHello,
    HealthResponse,
    ProtocolError
  }

  alias Zaq.ExtensionGateway

  @moduletag capture_log: true

  setup context do
    directory = Path.join(System.tmp_dir!(), "zs-#{System.unique_integer([:positive])}")
    settings = ExtensionGateway.certificates!(directory)

    gateway =
      ExtensionGateway.start!(
        directory,
        Keyword.take(Map.to_list(context), [:hello, :health_version])
        |> maybe_health_version_response()
      )

    on_exit(fn ->
      ExtensionGateway.stop(gateway)
      File.rm_rf!(directory)
    end)

    %{settings: settings, gateway: gateway, directory: directory}
  end

  test "health requests and responses reuse a bidirectional stream without half-closing",
       context do
    runtime =
      start_supervised!({Extension, name: nil, settings: context.settings, poll_interval_ms: 30})

    gateway = context.gateway
    assert_receive {:gateway_connected, ^gateway, handler}, 2_000
    assert_receive {:gateway_request, ^gateway, ^handler, _first}, 2_000
    assert_receive {:gateway_request, ^gateway, ^handler, _second}, 2_000
    assert %{status: :healthy, response_time_ms: elapsed} = Extension.snapshot(server: runtime)
    assert is_integer(elapsed) and elapsed >= 0
    refute_receive {:gateway_connected, ^gateway, _other}, 100
    refute_receive {:gateway_unary_health, ^gateway}, 50
  end

  test "gateway can send an unsupported future operation while no probe is outstanding",
       context do
    runtime = start_runtime(context, poll_interval_ms: 30_000)
    gateway = context.gateway
    await_health(runtime, :healthy)

    ExtensionGateway.push(gateway, %GatewayEnvelope{
      request_id: Ecto.UUID.generate(),
      protocol_version: 1,
      __unknown_fields__: [{40, 2, "future-operation"}]
    })

    assert_receive {:gateway_rejection, ^gateway, %{code: :UNSUPPORTED_OPERATION}}, 2_000

    assert %{reason: :unsupported_operation, response_time_ms: nil} =
             await_health(runtime, :error)
  end

  test "a gateway protocol error rejects the stream and reports an RPC health error", context do
    gateway = context.gateway

    with_healthy_runtime(
      context,
      [poll_interval_ms: 30_000, reconnect_interval_ms: 30],
      fn runtime, handler, handler_monitor ->
        %{connection_name: old_name} = :sys.get_state(runtime)
        ExtensionGateway.respond(gateway, {:await, {:ok, "ok"}})

        ExtensionGateway.push(gateway, %GatewayEnvelope{
          request_id: Ecto.UUID.generate(),
          protocol_version: 1,
          payload: {:error, %ProtocolError{code: :INVALID_ENVELOPE}}
        })

        assert_receive {:gateway_rejection, ^gateway, %{code: :INVALID_ENVELOPE}}, 2_000

        assert_recovery(
          context,
          runtime,
          handler,
          handler_monitor,
          old_name,
          :error,
          :rpc_error
        )
      end
    )
  end

  @tag hello:
         {:hello,
          %GatewayHello{
            selected_version: 2,
            capabilities: ["health.v1"],
            max_envelope_bytes: 262_144
          }}
  test "incompatible negotiation is rejected before any health request", context do
    runtime = start_runtime(context)
    gateway = context.gateway
    assert_receive {:gateway_rejection, ^gateway, %{code: :INCOMPATIBLE_PROTOCOL}}, 2_000
    assert %{reason: :incompatible_protocol} = await_health(runtime, :error)
    refute_received {:gateway_request, ^gateway, _, _}
  end

  @tag hello:
         {:await,
          {:hello,
           %GatewayHello{
             selected_version: 1,
             capabilities: ["health.v1"],
             max_envelope_bytes: 262_144
           }}}
  @tag health_version: 2
  test "a wrong-version health envelope is rejected after successful negotiation", context do
    runtime = start_runtime(context, poll_interval_ms: 30_000, reconnect_interval_ms: 30_000)
    gateway = context.gateway
    assert_receive {:gateway_connected, ^gateway, handler}, 2_000
    handler_monitor = Process.monitor(handler)
    hook_id = install_runtime_hook(runtime)
    %{connection_name: name} = :sys.get_state(runtime)

    try do
      send(handler, {:release, gateway})
      assert_receive {:gateway_request, ^gateway, ^handler, _first_probe}, 2_000
      assert_receive {:gateway_rejection, ^gateway, %{code: :INCOMPATIBLE_PROTOCOL}}, 2_000
      assert_health_transition(runtime, :error, :incompatible_protocol)
      await_connection_cleanup(runtime, name)
      assert_receive {:DOWN, ^handler_monitor, :process, ^handler, _reason}, 2_000
    after
      send(handler, {:release, gateway})
      :sys.remove(runtime, hook_id)
    end
  end

  @tag hello:
         {:hello,
          %GatewayHello{selected_version: 1, capabilities: [], max_envelope_bytes: 262_144}}
  test "missing health capability cannot report a healthy stream", context do
    runtime = start_runtime(context)
    assert %{reason: :incompatible_protocol} = await_health(runtime, :error)
  end

  @tag hello: :unimplemented
  test "legacy Health-only gateways do not trigger a separate Health connection", context do
    runtime = start_runtime(context)
    gateway = context.gateway
    assert %{reason: :rpc_error} = await_health(runtime, :error)
    refute_received {:gateway_unary_health, ^gateway}
    refute_received {:gateway_request, ^gateway, _, _}
  end

  test "a wrong correlation id cannot satisfy a health deadline", context do
    gateway = context.gateway

    ExtensionGateway.respond(
      gateway,
      {:frame,
       %GatewayEnvelope{
         request_id: Ecto.UUID.generate(),
         protocol_version: 1,
         payload: {:health_response, %HealthResponse{status: "ok"}}
       }}
    )

    runtime = start_runtime(context, probe_timeout_ms: 500)
    assert_receive {:gateway_request, ^gateway, _, _}, 2_000
    assert %{reason: :timeout, response_time_ms: nil} = await_health(runtime, :unreachable)
  end

  test "a second probe while one is pending times out the stream", context do
    gateway = context.gateway

    with_healthy_runtime(
      context,
      [poll_interval_ms: 30_000, probe_timeout_ms: 30_000, reconnect_interval_ms: 30],
      fn runtime, handler, handler_monitor ->
        %{connection_name: old_name} = :sys.get_state(runtime)
        ExtensionGateway.respond(gateway, {:await, {:ok, "ok"}})
        send(runtime, :probe)
        assert_receive {:gateway_request, ^gateway, ^handler, _first_probe}, 2_000
        send(runtime, :probe)

        assert_recovery(
          context,
          runtime,
          handler,
          handler_monitor,
          old_name,
          :unreachable,
          :timeout
        )
      end
    )
  end

  @tag hello:
         {:hello,
          %GatewayHello{
            selected_version: 1,
            capabilities: ["health.v1"],
            max_envelope_bytes: 1_024
          }}
  test "negotiated limits reject oversized control envelopes", context do
    runtime = start_runtime(context)
    gateway = context.gateway
    await_health(runtime, :healthy)
    assert :sys.get_state(runtime).max_envelope_bytes == 1_024

    ExtensionGateway.push(gateway, %GatewayEnvelope{
      request_id: Ecto.UUID.generate(),
      protocol_version: 1,
      payload: {:health_response, %HealthResponse{status: String.duplicate("x", 1_025)}}
    })

    assert %{reason: :resource_exhausted} = await_health(runtime, :error)
    assert_receive {:gateway_rejection, ^gateway, %{code: :RESOURCE_EXHAUSTED}}, 2_000
  end

  @tag hello:
         {:hello,
          %GatewayHello{
            selected_version: 1,
            capabilities: ["health.v1"],
            max_envelope_bytes: 1_024
          }}
  test "the negotiated limit counts original bytes, not a re-encoded message", context do
    gateway = context.gateway
    ExtensionGateway.respond(gateway, {:await, {:ok, "ok"}})
    runtime = start_runtime(context)
    assert_receive {:gateway_request, ^gateway, handler, _}, 2_000

    frame = %GatewayEnvelope{
      request_id: :sys.get_state(runtime).pending.id,
      protocol_version: 1,
      payload: {:health_response, %HealthResponse{status: String.duplicate("x", 978)}}
    }

    exact = GatewayEnvelope.encode(frame)
    assert byte_size(exact) == 1_024
    suffix = GatewayEnvelope.encode(%GatewayEnvelope{protocol_version: 1})
    oversized = exact <> suffix
    assert GatewayEnvelope.encode(GatewayEnvelope.decode(oversized)) == exact

    ExtensionGateway.push_wire(gateway, <<0, byte_size(exact)::32, exact::binary>>)
    assert %{reason: :unexpected_status} = await_error(runtime, :unexpected_status)
    ExtensionGateway.push_wire(gateway, <<0, byte_size(oversized)::32, oversized::binary>>)
    assert %{reason: :resource_exhausted} = await_error(runtime, :resource_exhausted)

    send(handler, {:release, gateway})
    assert_receive {:gateway_rejection, ^gateway, %{code: :RESOURCE_EXHAUSTED}}, 2_000
  end

  test "disconnect invalidates health immediately and reconnect uses a new stream", context do
    runtime = start_runtime(context, poll_interval_ms: 10_000, reconnect_interval_ms: 30)
    gateway = context.gateway
    assert_receive {:gateway_connected, ^gateway, first}, 2_000
    await_health(runtime, :healthy)
    old_generation = :sys.get_state(runtime).generation
    ExtensionGateway.stop(gateway)
    await_health(runtime, :unreachable)
    restarted = ExtensionGateway.start!(context.directory)
    assert_receive {:gateway_connected, ^restarted, second}, 2_000
    refute first == second
    await_health(runtime, :healthy)

    stale = %GatewayEnvelope{request_id: Ecto.UUID.generate(), protocol_version: 1}
    received_at = System.monotonic_time(:millisecond)

    assert {:reject, :invalid_envelope} =
             GenServer.call(runtime, {:extension_frame, old_generation, stale, received_at})

    assert %{status: :healthy} = Extension.snapshot(server: runtime)
  end

  test "stopping the runtime closes its named persistent connection and reader", context do
    runtime = start_runtime(context)
    await_health(runtime, :healthy)
    %{reader: reader, connection_name: name} = :sys.get_state(runtime)
    monitor = Process.monitor(reader.pid)
    GenServer.stop(runtime)
    assert_receive {:DOWN, ^monitor, :process, _, _}, 2_000
    assert {:error, :not_started} = Connection.get_channel(name)
  end

  test "reader death cancels its sibling writer and makes the stream unreachable", context do
    gateway = context.gateway

    with_healthy_runtime(
      context,
      [poll_interval_ms: 30_000, probe_timeout_ms: 10_000, reconnect_interval_ms: 30],
      fn runtime, handler, handler_monitor ->
        %{reader: reader, writer: writer, connection_name: old_name} = :sys.get_state(runtime)
        reader_monitor = Process.monitor(reader.pid)
        writer_monitor = Process.monitor(writer.pid)
        ExtensionGateway.respond(gateway, {:await, {:ok, "ok"}})
        send(runtime, :probe)
        assert_receive {:gateway_request, ^gateway, ^handler, _held_probe}, 2_000
        assert %{status: :healthy, reason: nil} = Extension.snapshot(server: runtime)

        Process.exit(reader.pid, :kill)
        assert_receive {:DOWN, ^reader_monitor, :process, _, :killed}, 2_000
        assert_receive {:DOWN, ^writer_monitor, :process, _, _}, 2_000

        assert_recovery(
          context,
          runtime,
          handler,
          handler_monitor,
          old_name,
          :unreachable,
          :unreachable
        )
      end
    )
  end

  test "writer death cancels its sibling reader and makes the stream unreachable", context do
    gateway = context.gateway

    with_healthy_runtime(
      context,
      [poll_interval_ms: 30_000, probe_timeout_ms: 10_000, reconnect_interval_ms: 30],
      fn runtime, handler, handler_monitor ->
        %{reader: reader, writer: writer, connection_name: old_name} = :sys.get_state(runtime)
        reader_monitor = Process.monitor(reader.pid)
        writer_monitor = Process.monitor(writer.pid)
        ExtensionGateway.respond(gateway, {:await, {:ok, "ok"}})
        send(runtime, :probe)
        assert_receive {:gateway_request, ^gateway, ^handler, _held_probe}, 2_000
        assert %{status: :healthy, reason: nil} = Extension.snapshot(server: runtime)

        Process.exit(writer.pid, :kill)
        assert_receive {:DOWN, ^writer_monitor, :process, _, :killed}, 2_000
        assert_receive {:DOWN, ^reader_monitor, :process, _, _}, 2_000

        assert_recovery(
          context,
          runtime,
          handler,
          handler_monitor,
          old_name,
          :unreachable,
          :unreachable
        )
      end
    )
  end

  test "a normal writer stop result disconnects the reader and reports unreachable", context do
    gateway = context.gateway

    with_healthy_runtime(
      context,
      [poll_interval_ms: 30_000, probe_timeout_ms: 10_000, reconnect_interval_ms: 30],
      fn runtime, handler, handler_monitor ->
        %{reader: reader, writer: writer, connection_name: old_name} = :sys.get_state(runtime)
        reader_monitor = Process.monitor(reader.pid)
        writer_monitor = Process.monitor(writer.pid)
        writer_ref = writer.ref
        writer_result_hook = install_writer_result_hook(runtime, writer_ref)
        ExtensionGateway.respond(gateway, {:await, {:ok, "ok"}})
        send(runtime, :probe)
        assert_receive {:gateway_request, ^gateway, ^handler, _held_probe}, 2_000
        true = :erlang.suspend_process(reader.pid)

        try do
          send(writer.pid, :stop)
          assert_receive {:writer_ok_result, ^runtime, ^writer_ref}, 2_000
          assert_receive {:DOWN, ^writer_monitor, :process, _, :normal}, 2_000
          assert_receive {:DOWN, ^reader_monitor, :process, _, _}, 2_000

          assert_recovery(
            context,
            runtime,
            handler,
            handler_monitor,
            old_name,
            :unreachable,
            :unreachable
          )
        after
          if Process.alive?(reader.pid) do
            case :erlang.process_info(reader.pid, :status) do
              {:status, :suspended} -> :erlang.resume_process(reader.pid)
              _ -> :ok
            end
          end

          :sys.remove(runtime, writer_result_hook)
        end
      end
    )
  end

  test "reader loss fences the old stream and rejects oversized stale frames during recovery",
       context do
    gateway = context.gateway

    with_healthy_runtime(
      context,
      [poll_interval_ms: 30_000, probe_timeout_ms: 10_000, reconnect_interval_ms: 30],
      fn runtime, first_handler, first_handler_monitor ->
        %{reader: reader, connection_name: old_name, generation: old_generation} =
          :sys.get_state(runtime)

        ExtensionGateway.respond(gateway, {:await, {:ok, "ok"}})
        send(runtime, :probe)
        assert_receive {:gateway_request, ^gateway, ^first_handler, _held_probe}, 2_000
        reader_monitor = Process.monitor(reader.pid)
        Process.exit(reader.pid, :kill)
        assert_receive {:DOWN, ^reader_monitor, :process, _, :killed}, 2_000

        assert_health_transition(runtime, :unreachable, :unreachable)
        await_connection_cleanup(runtime, old_name)
        send(first_handler, {:release, gateway})
        assert_receive {:DOWN, ^first_handler_monitor, :process, ^first_handler, _}, 2_000

        assert_receive {:gateway_connected, ^gateway, replacement}, 2_000
        replacement_monitor = Process.monitor(replacement)

        try do
          refute replacement == first_handler
          assert_receive {:gateway_request, ^gateway, ^replacement, _replacement_probe}, 2_000
          before_stale_frame = Extension.snapshot(server: runtime)

          assert %{status: :unreachable, reason: :unreachable, response_time_ms: nil} =
                   before_stale_frame

          assert {:reject, :resource_exhausted} =
                   GenServer.call(runtime, {:oversized_extension_frame, old_generation})

          assert ^before_stale_frame = Extension.snapshot(server: runtime)
          send(replacement, {:release, gateway})
          assert_receive {:health_reply_applied, ^runtime}, 2_000

          assert %{status: :healthy, reason: nil, response_time_ms: elapsed} =
                   Extension.snapshot(server: runtime)

          assert is_integer(elapsed) and elapsed >= 0
        after
          send(replacement, {:release, gateway})
          Process.demonitor(replacement_monitor, [:flush])
        end
      end
    )
  end

  test "an abruptly killed stream owner cannot leave its adapter connection running", context do
    spec =
      Supervisor.child_spec({Extension, name: nil, settings: context.settings},
        restart: :temporary
      )

    runtime = start_supervised!(spec)
    await_health(runtime, :healthy)
    %{connection_name: name} = :sys.get_state(runtime)
    manager = GenServer.whereis({:via, Registry, {GRPC.Client.Registry, {Connection, name}}})
    monitor = Process.monitor(manager)
    Process.exit(runtime, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^manager, _}, 2_000
    assert {:error, :not_started} = Connection.get_channel(name)
  end

  test "supervisor shutdown releases both stream tasks and their connection", context do
    runtime = start_runtime(context)
    await_health(runtime, :healthy)
    %{reader: reader, writer: writer, connection_name: name} = :sys.get_state(runtime)
    reader_monitor = Process.monitor(reader.pid)
    writer_monitor = Process.monitor(writer.pid)
    stop_supervised!(Extension)
    assert_receive {:DOWN, ^reader_monitor, :process, _, _}, 2_000
    assert_receive {:DOWN, ^writer_monitor, :process, _, _}, 2_000
    assert {:error, :not_started} = Connection.get_channel(name)
  end

  test "an oversized frame prefix is rejected without waiting for its body", context do
    runtime = start_runtime(context)
    await_health(runtime, :healthy)
    limit = Protocol.max_envelope_bytes()
    ExtensionGateway.push_wire(context.gateway, <<0, limit + 1::32>>)
    assert %{reason: :resource_exhausted, response_time_ms: nil} = await_health(runtime, :error)
  end

  test "malformed protobuf terminates only its stream and never reports healthy", context do
    runtime = start_runtime(context)
    await_health(runtime, :healthy)
    ExtensionGateway.push_wire(context.gateway, <<0, 1::32, 255>>)
    assert %{reason: :rpc_error, response_time_ms: nil} = await_health(runtime, :error)
    assert Process.alive?(runtime)
  end

  @tag timeout: 15_000
  test "the stream stays open beyond the default five-second RPC timeout", context do
    runtime = start_runtime(context, poll_interval_ms: 6_000)
    gateway = context.gateway
    assert_receive {:gateway_connected, ^gateway, handler}, 2_000
    assert_receive {:gateway_request, ^gateway, ^handler, _first}, 2_000
    await_health(runtime, :healthy)
    assert_receive {:gateway_request, ^gateway, ^handler, _second}, 8_000
    assert %{status: :healthy} = Extension.snapshot(server: runtime)
    refute_received {:gateway_connected, ^gateway, _other}
  end

  defp start_runtime(context, opts \\ []) do
    start_supervised!({Extension, [name: nil, settings: context.settings] ++ opts})
  end

  defp maybe_health_version_response(opts) do
    case Keyword.fetch(opts, :health_version) do
      {:ok, version} -> Keyword.put(opts, :response, {:health_version, version})
      :error -> opts
    end
  end

  defp install_runtime_hook(runtime) do
    owner = self()

    hook = fn hook_state, event, _process_state ->
      case event do
        {:out, :continue, _to, _state} ->
          send(owner, {:health_reply_applied, runtime})
          hook_state

        {:out, {:reject, _reason}, _to, %{health: %{status: status, reason: reason}}} ->
          send(owner, {:health_transition, runtime, status, reason})
          hook_state

        {:noreply,
         %{phase: :cleanup, cleanup: %{pid: pid}, health: %{status: status, reason: reason}}} ->
          send(owner, {:health_transition, runtime, status, reason})
          send(owner, {:extension_cleanup, runtime, pid})
          hook_state

        _ ->
          hook_state
      end
    end

    hook_id = make_ref()
    :ok = :sys.install(runtime, {hook_id, hook, runtime})
    hook_id
  end

  defp install_writer_result_hook(runtime, writer_ref) do
    owner = self()

    hook = fn hook_state, event, _process_state ->
      case event do
        {:in, {^writer_ref, :ok}, _state} ->
          send(owner, {:writer_ok_result, runtime, writer_ref})
          hook_state

        {:in, {^writer_ref, :ok}} ->
          send(owner, {:writer_ok_result, runtime, writer_ref})
          hook_state

        _ ->
          hook_state
      end
    end

    hook_id = make_ref()
    :ok = :sys.install(runtime, {hook_id, hook, runtime})
    hook_id
  end

  defp with_healthy_runtime(context, opts, fun) do
    gateway = context.gateway
    ExtensionGateway.respond(gateway, {:await, {:ok, "ok"}})
    runtime = start_runtime(context, Keyword.merge([poll_interval_ms: 30_000], opts))
    hook_id = install_runtime_hook(runtime)
    assert_receive {:gateway_connected, ^gateway, handler}, 2_000
    handler_monitor = Process.monitor(handler)

    try do
      assert_receive {:gateway_request, ^gateway, ^handler, _probe}, 2_000
      send(handler, {:release, gateway})
      assert_receive {:health_reply_applied, ^runtime}, 2_000

      assert %{status: :healthy, reason: nil, response_time_ms: elapsed} =
               Extension.snapshot(server: runtime)

      assert is_integer(elapsed) and elapsed >= 0
      fun.(runtime, handler, handler_monitor)
    after
      send(handler, {:release, gateway})
      :sys.remove(runtime, hook_id)
    end
  end

  defp assert_health_transition(runtime, status, reason) do
    assert_receive {:health_transition, ^runtime, ^status, ^reason}, 2_000

    assert %{status: ^status, reason: ^reason, response_time_ms: nil} =
             Extension.snapshot(server: runtime)
  end

  defp await_connection_cleanup(runtime, name) do
    assert_receive {:extension_cleanup, ^runtime, cleanup_pid}, 2_000
    monitor = Process.monitor(cleanup_pid)
    assert_receive {:DOWN, ^monitor, :process, ^cleanup_pid, _reason}, 2_000
    assert {:error, :not_started} = Connection.get_channel(name)
  end

  defp assert_recovery(
         context,
         runtime,
         old_handler,
         old_handler_monitor,
         old_name,
         status,
         reason
       ) do
    gateway = context.gateway
    assert_health_transition(runtime, status, reason)
    await_connection_cleanup(runtime, old_name)
    send(old_handler, {:release, gateway})
    assert_receive {:DOWN, ^old_handler_monitor, :process, ^old_handler, _reason}, 2_000

    assert_receive {:gateway_connected, ^gateway, replacement}, 2_000
    replacement_monitor = Process.monitor(replacement)

    try do
      refute replacement == old_handler
      assert_receive {:gateway_request, ^gateway, ^replacement, _probe}, 2_000

      assert %{status: ^status, reason: ^reason, response_time_ms: nil} =
               Extension.snapshot(server: runtime)

      send(replacement, {:release, gateway})
      assert_receive {:health_reply_applied, ^runtime}, 2_000

      assert %{status: :healthy, reason: nil, response_time_ms: elapsed} =
               Extension.snapshot(server: runtime)

      assert is_integer(elapsed) and elapsed >= 0
    after
      send(replacement, {:release, gateway})
      Process.demonitor(replacement_monitor, [:flush])
    end
  end

  defp await_health(runtime, status) do
    await_snapshot(runtime, &(&1.status == status), "health did not reach #{status}")
  end

  defp await_error(runtime, reason) do
    await_snapshot(
      runtime,
      &(&1.status == :error and &1.reason == reason),
      "health did not report #{reason}"
    )
  end

  defp await_snapshot(runtime, matches?, failure) do
    deadline = System.monotonic_time(:millisecond) + 2_000

    Stream.repeatedly(fn -> Extension.snapshot(server: runtime) end)
    |> Enum.find(fn health ->
      if System.monotonic_time(:millisecond) > deadline,
        do: flunk(failure)

      if matches?.(health) do
        true
      else
        Process.sleep(5)
        false
      end
    end)
  end
end

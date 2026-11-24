defmodule Zaq.Engine.Extension.StreamIntegrationTest do
  use ExUnit.Case, async: true

  alias GRPC.Client.Connection
  alias Zaq.Engine.Extension
  alias Zaq.Engine.Extension.Protocol
  alias Zaq.Engine.Extension.Rpc.Gateway.V1.{GatewayEnvelope, GatewayHello, HealthResponse}
  alias Zaq.ExtensionGateway

  @moduletag capture_log: true

  setup context do
    directory = Path.join(System.tmp_dir!(), "zs-#{System.unique_integer([:positive])}")
    settings = ExtensionGateway.certificates!(directory)
    gateway = ExtensionGateway.start!(directory, Keyword.take(Map.to_list(context), [:hello]))

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

    assert {:reject, :invalid_envelope} =
             GenServer.call(runtime, {:extension_frame, old_generation, stale})

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

defmodule Zaq.Engine.Extension.ClientIntegrationTest do
  use ExUnit.Case, async: true

  alias GRPC.Client.Connection
  alias Zaq.Engine.Extension
  alias Zaq.Engine.Extension.Client
  alias Zaq.ExtensionGateway

  @moduletag capture_log: true

  setup context do
    directory = Path.join(System.tmp_dir!(), "zx-#{System.unique_integer([:positive])}")
    settings = ExtensionGateway.certificates!(directory)
    gateway = unless context[:raw_peer], do: ExtensionGateway.start!(directory)

    on_exit(fn ->
      if gateway, do: ExtensionGateway.stop(gateway)
      File.rm_rf!(directory)
    end)

    %{settings: settings, directory: directory, gateway: gateway}
  end

  test "protobuf Health succeeds using TLS 1.3, mutual authentication and h2", %{
    settings: settings
  } do
    name = make_ref()
    assert {:ok, :healthy} = Client.health(settings: settings, connection_name: name)
    assert {:error, :not_started} = Connection.get_channel(name)
    assert {:ok, :healthy} = Client.health(settings: settings)
  end

  test "rejects wrong server identity and a client certificate with server-only usage", %{
    settings: settings,
    directory: directory
  } do
    assert {:error, :tls_error} =
             Client.health(settings: Keyword.put(settings, :server_name, "wrong.local"))

    invalid_client =
      Keyword.merge(settings,
        client_cert: Path.join(directory, "server.pem"),
        client_key: Path.join(directory, "server.key")
      )

    assert {:error, reason} = Client.health(settings: invalid_client)
    assert reason in [:tls_error, :rpc_error]
  end

  test "rejects an unrelated trust root", %{settings: settings, directory: directory} do
    rogue = ExtensionGateway.certificates!(Path.join(directory, "rogue"))

    assert {:error, :tls_error} =
             Client.health(settings: Keyword.put(settings, :ca_cert, rogue[:ca_cert]))
  end

  test "missing socket is unreachable, not healthy", %{settings: settings} do
    assert {:error, :unreachable} =
             Client.health(settings: Keyword.update!(settings, :socket_path, &(&1 <> ".absent")))
  end

  @tag :raw_peer
  test "TLS peer without h2 ALPN is rejected before any HTTP data", %{
    settings: settings,
    directory: directory
  } do
    path = Path.join(directory, "no-alpn.sock")

    {:ok, listener} =
      :ssl.listen(0, [
        :binary,
        active: false,
        ifaddr: {:local, path},
        versions: [:"tlsv1.3"],
        certfile: Path.join(directory, "server.pem"),
        keyfile: Path.join(directory, "server.key"),
        cacertfile: settings[:ca_cert],
        verify: :verify_peer,
        fail_if_no_peer_cert: true
      ])

    on_exit(fn -> :ssl.close(listener) end)

    peer =
      Task.async(fn ->
        {:ok, socket} = :ssl.transport_accept(listener, 2_000)
        {:ok, socket} = :ssl.handshake(socket, 2_000)
        :ssl.recv(socket, 0, 2_000)
      end)

    assert {:error, :tls_error} =
             Client.health(settings: Keyword.put(settings, :socket_path, path))

    assert {:error, :closed} = Task.await(peer)
  end

  @tag :raw_peer
  test "a peer that accepts but never completes TLS is bounded and released", %{
    settings: settings,
    directory: directory
  } do
    path = Path.join(directory, "stall.sock")
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, path}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    name = make_ref()
    started = System.monotonic_time(:millisecond)

    assert {:error, :unreachable} =
             Client.health(
               settings: Keyword.put(settings, :socket_path, path),
               connection_name: name
             )

    assert System.monotonic_time(:millisecond) - started < 5_000
    assert {:error, :not_started} = Connection.get_channel(name)
  end

  test "Engine cache recovers from a real gateway outage without blocking readers", %{
    settings: settings,
    directory: directory,
    gateway: gateway
  } do
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    runtime =
      start_supervised!(
        {Extension,
         name: nil,
         settings: settings,
         poll_interval_ms: 50,
         clock: fn -> Agent.get(clock, & &1) end}
      )

    assert_health(runtime, :healthy)
    Agent.update(clock, fn _ -> 50_000 end)
    assert %{status: :unreachable, reason: :stale} = Extension.snapshot(server: runtime)
    Agent.update(clock, fn _ -> 0 end)

    ExtensionGateway.stop(gateway)
    assert_health(runtime, :unreachable)
    restarted = ExtensionGateway.start!(directory)
    on_exit(fn -> ExtensionGateway.stop(restarted) end)
    assert_health(runtime, :healthy)
  end

  test "Engine caches full-probe milliseconds and clears them after a failed check", %{
    settings: settings,
    gateway: gateway
  } do
    runtime = start_supervised!({Extension, name: nil, settings: settings, poll_interval_ms: 50})
    assert_health(runtime, :healthy)

    health = Extension.snapshot(server: runtime)
    assert %DateTime{} = health.checked_at
    assert is_integer(health.response_time_ms)
    assert health.response_time_ms >= 0

    ExtensionGateway.stop(gateway)
    assert_health(runtime, :unreachable)
    assert %{response_time_ms: nil} = Extension.snapshot(server: runtime)
  end

  test "Engine duration uses elapsed monotonic time, including zero at a negative clock origin",
       %{
         settings: settings
       } do
    runtime =
      start_supervised!({Extension, name: nil, settings: settings, clock: fn -> -1_000 end})

    assert_health(runtime, :healthy)
    assert %{response_time_ms: 0} = Extension.snapshot(server: runtime)
  end

  test "controlled protobuf responses and gRPC errors use the production client's safe reasons",
       %{
         settings: settings,
         gateway: gateway
       } do
    ExtensionGateway.respond(gateway, {:ok, "not-ready"})
    assert {:error, :unexpected_status} = Client.health(settings: settings)
    ExtensionGateway.respond(gateway, {:error, :unavailable})
    assert {:error, :rpc_error} = Client.health(settings: settings)
  end

  test "a delayed response measures exact monotonic elapsed time and an RPC failure clears it", %{
    settings: settings,
    gateway: gateway
  } do
    {:ok, clock} = Agent.start_link(fn -> -100 end)
    ExtensionGateway.respond(gateway, {:await, {:ok, "ok"}})

    runtime =
      start_supervised!(
        {Extension,
         name: nil,
         settings: settings,
         poll_interval_ms: 50,
         clock: fn -> Agent.get(clock, & &1) end}
      )

    assert_receive {:gateway_request, ^gateway, handler, _request}, 2_000
    assert %{status: :checking} = Extension.snapshot(server: runtime)
    Agent.update(clock, fn _ -> -58 end)
    send(handler, {:release, gateway})
    assert_health(runtime, :healthy)
    assert %{response_time_ms: 42} = Extension.snapshot(server: runtime)

    ExtensionGateway.respond(gateway, {:error, :unavailable})
    assert_health(runtime, :error)
    assert %{reason: :rpc_error, response_time_ms: nil} = Extension.snapshot(server: runtime)
  end

  test "an unanswered RPC clears a prior response time when the Engine deadline expires", %{
    settings: settings,
    gateway: gateway
  } do
    runtime =
      start_supervised!(
        {Extension, name: nil, settings: settings, poll_interval_ms: 50, probe_timeout_ms: 1_000}
      )

    assert_health(runtime, :healthy)
    assert_receive {:gateway_request, ^gateway, _first_handler, _request}, 2_000

    ExtensionGateway.respond(gateway, {:await, {:ok, "ok"}})
    assert_receive {:gateway_request, ^gateway, _blocked_handler, _request}, 2_000
    assert_health(runtime, :unreachable)
    assert %{reason: :timeout, response_time_ms: nil} = Extension.snapshot(server: runtime)
  end

  test "the client bounds a protobuf RPC whose handler never replies", %{
    settings: settings,
    gateway: gateway
  } do
    ExtensionGateway.respond(gateway, {:await, {:ok, "ok"}})
    started = System.monotonic_time(:millisecond)
    assert {:error, :rpc_error} = Client.health(settings: settings)
    assert System.monotonic_time(:millisecond) - started < 5_000
  end

  defp assert_health(runtime, status, attempts \\ 200)
  defp assert_health(_runtime, _status, 0), do: flunk("gateway health did not settle")

  defp assert_health(runtime, status, attempts) do
    if Extension.snapshot(server: runtime).status == status do
      :ok
    else
      Process.sleep(10)
      assert_health(runtime, status, attempts - 1)
    end
  end
end

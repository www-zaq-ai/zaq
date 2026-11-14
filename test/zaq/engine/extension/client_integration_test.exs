defmodule Zaq.Engine.Extension.ClientIntegrationTest do
  use ExUnit.Case, async: true

  alias GRPC.Client.Connection
  alias Zaq.Engine.Extension
  alias Zaq.Engine.Extension.Client
  alias Zaq.ExtensionGateway

  @moduletag :integration

  setup do
    directory = Path.join(System.tmp_dir!(), "zx-#{System.unique_integer([:positive])}")
    settings = ExtensionGateway.certificates!(directory)
    gateway = ExtensionGateway.start!(directory)

    on_exit(fn ->
      ExtensionGateway.stop(gateway)
      File.rm_rf!(directory)
    end)

    %{settings: settings, directory: directory, gateway: gateway}
  end

  test "real Rust Health succeeds using TLS 1.3, mutual authentication and h2", %{
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

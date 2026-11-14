defmodule Zaq.Engine.Extension.ClientIntegrationTest do
  use ExUnit.Case, async: true

  alias GRPC.Client.Connection
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

    %{settings: settings, directory: directory}
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

    assert {:error, :tls_error} = Client.health(settings: invalid_client)
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
end

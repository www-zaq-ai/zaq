defmodule Zaq.Engine.Extension.GatewayFixtureTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Extension.Client
  alias Zaq.ExtensionGateway

  @moduletag capture_log: true

  setup do
    directory =
      Path.join(System.tmp_dir!(), "zf-#{System.pid()}-#{System.unique_integer([:positive])}")

    settings = ExtensionGateway.certificates!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory, settings: settings}
  end

  test "protobuf server uses the real client and supports private socket lifecycle", %{
    directory: directory,
    settings: settings
  } do
    gateway = ExtensionGateway.start!(directory, response: {:ok, "ok"})
    assert Bitwise.band(File.stat!(directory).mode, 0o777) == 0o700
    assert Bitwise.band(File.stat!(settings[:socket_path]).mode, 0o777) == 0o600
    assert {:ok, :healthy} = Client.health(settings: settings)

    ExtensionGateway.stop(gateway)
    refute File.exists?(settings[:socket_path])
    assert {:error, :unreachable} = Client.health(settings: settings)
    ExtensionGateway.start!(directory)
    assert {:ok, :healthy} = Client.health(settings: settings)
  end

  test "simultaneous listeners have independent responses and cleanup", %{
    directory: directory,
    settings: settings
  } do
    first = ExtensionGateway.start!(directory)

    other =
      Path.join(System.tmp_dir!(), "zg-#{System.pid()}-#{System.unique_integer([:positive])}")

    other_settings = ExtensionGateway.certificates!(other)
    on_exit(fn -> File.rm_rf!(other) end)
    ExtensionGateway.start!(other, response: {:ok, "not-ready"})

    assert {:ok, :healthy} = Client.health(settings: settings)
    assert {:error, :unexpected_status} = Client.health(settings: other_settings)
    ExtensionGateway.stop(first)
    assert {:error, :unexpected_status} = Client.health(settings: other_settings)
  end

  test "listener setup failure leaves no socket or listener behind", %{
    directory: directory,
    settings: settings
  } do
    File.rm!(Path.join(directory, "server.key"))
    assert {:error, _} = start_supervised({ExtensionGateway, {directory, []}})
    refute File.exists?(settings[:socket_path])
  end

  test "failed duplicate setup does not remove another listener's socket", %{
    directory: directory,
    settings: settings
  } do
    ExtensionGateway.start!(directory)
    assert {:error, _} = start_supervised({ExtensionGateway, {directory, []}}, id: make_ref())
    assert {:ok, :healthy} = Client.health(settings: settings)
  end

  test "the fixture negotiates TLS 1.3 and h2", %{directory: directory, settings: settings} do
    ExtensionGateway.start!(directory)

    {:ok, socket} =
      tls_connect(settings, certfile: settings[:client_cert], keyfile: settings[:client_key])

    assert {:ok, [protocol: :"tlsv1.3"]} = :ssl.connection_information(socket, [:protocol])
    assert {:ok, "h2"} = :ssl.negotiated_protocol(socket)
    :ssl.close(socket)
  end

  test "the fixture rejects a TLS peer without a client certificate", %{
    directory: directory,
    settings: settings
  } do
    ExtensionGateway.start!(directory)

    result =
      case tls_connect(settings, []) do
        {:ok, socket} ->
          result = :ssl.recv(socket, 0, 2_000)
          :ssl.close(socket)
          result

        error ->
          error
      end

    assert {:error, reason} = result
    assert match?({:tls_alert, _}, reason) or reason == :closed
  end

  test "the fixture rejects a TLS 1.2 downgrade", %{directory: directory, settings: settings} do
    ExtensionGateway.start!(directory)

    assert {:error, {:tls_alert, {:protocol_version, _}}} =
             tls_connect(
               settings,
               [certfile: settings[:client_cert], keyfile: settings[:client_key]],
               [
                 :"tlsv1.2"
               ]
             )
  end

  defp tls_connect(settings, identity, versions \\ [:"tlsv1.3"]) do
    {:ok, socket} =
      :gen_tcp.connect({:local, settings[:socket_path]}, 0, [:binary, active: false], 2_000)

    result =
      :ssl.connect(
        socket,
        identity ++
          [
            active: false,
            verify: :verify_peer,
            cacertfile: settings[:ca_cert],
            versions: versions,
            server_name_indication: ~c"gateway.local",
            alpn_advertised_protocols: ["h2"]
          ],
        2_000
      )

    if match?({:error, _}, result), do: :gen_tcp.close(socket)
    result
  end
end

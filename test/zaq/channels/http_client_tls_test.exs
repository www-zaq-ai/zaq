defmodule Zaq.Channels.HttpClient.TLSTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.HttpClient.Transport

  setup_all do
    directory = Path.join(System.tmp_dir!(), "zaq-http-tls-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    certs = Zaq.WidgetTLSFixtures.certificates(directory)
    ip_directory = Path.join(directory, "ip")
    File.mkdir_p!(ip_directory)
    ip_certs = Zaq.WidgetTLSFixtures.certificates(ip_directory, subject_alt_name: "IP:127.0.0.1")
    %{certificates: certs, ip_certificates: ip_certs}
  end

  test "numeric connection preserves Host, SNI and verification of the original hostname", %{
    certificates: certs
  } do
    {listener, port, peer} = peer(certs)
    url = "https://localhost:#{port}/signed"

    assert {:ok, %{body: "signed"}} =
             Transport.request(options(url, certs), [{127, 0, 0, 1}])

    assert_receive {:sni, ~c"localhost"}
    assert Task.await(peer) =~ "host: localhost:#{port}\r\n"
    :ssl.close(listener)
  end

  test "hostname mismatch fails without sending an HTTP request or trying another candidate", %{
    certificates: certs
  } do
    {_listener, port, peer} = peer(certs)
    url = "https://mismatch.invalid:#{port}/signed"

    assert {:error, %Req.TransportError{reason: {:tls_alert, _}}} =
             Transport.request(options(url, certs), [{127, 0, 0, 1}, {127, 0, 0, 2}])

    assert_receive {:sni, ~c"mismatch.invalid"}
    assert {:error, _} = Task.await(peer)
  end

  test "literal IP requires a matching IP certificate identity", %{certificates: certs} do
    {_listener, port, peer} = peer(certs)

    assert {:error, %Req.TransportError{reason: {:tls_alert, _}}} =
             Transport.request(options("https://127.0.0.1:#{port}/", certs), [{127, 0, 0, 1}])

    assert {:error, _} = Task.await(peer)
  end

  test "a trusted matching IP certificate succeeds for an explicit IP", %{ip_certificates: certs} do
    {_listener, port, peer} = peer(certs)

    assert {:ok, %{body: "signed"}} =
             Transport.request(options("https://127.0.0.1:#{port}/", certs), [{127, 0, 0, 1}])

    assert Task.await(peer) =~ "host: 127.0.0.1:#{port}\r\n"
  end

  test "TLS defaults cannot disable original hostname verification", %{certificates: certs} do
    {_listener, port, peer} = peer(certs)

    options = [
      url: "https://mismatch.invalid:#{port}/",
      receive_timeout: 2_000,
      retry: false,
      redirect: false,
      connect_options: [
        transport_opts: [
          cacertfile: certs.cacertfile,
          verify: :verify_none,
          server_name_indication: ~c"localhost"
        ]
      ]
    ]

    assert {:error, %Req.TransportError{reason: {:tls_alert, _}}} =
             Transport.request(options, [{127, 0, 0, 1}])

    assert_receive {:sni, ~c"mismatch.invalid"}
    assert {:error, _} = Task.await(peer)
  end

  test "an untrusted certificate is rejected", %{certificates: certs} do
    {_listener, port, peer} = peer(certs)

    assert {:error, %Req.TransportError{reason: {:tls_alert, _}}} =
             Transport.request(
               [
                 url: "https://localhost:#{port}/",
                 receive_timeout: 2_000,
                 retry: false,
                 redirect: false
               ],
               [{127, 0, 0, 1}]
             )

    assert {:error, _} = Task.await(peer)
  end

  defp options(url, certs) do
    [
      url: url,
      receive_timeout: 2_000,
      retry: false,
      redirect: false,
      connect_options: [transport_opts: [cacertfile: certs.cacertfile]]
    ]
  end

  defp peer(certs) do
    owner = self()

    {:ok, listener} =
      :ssl.listen(0, [
        :binary,
        active: false,
        ip: {127, 0, 0, 1},
        certfile: certs.certfile,
        keyfile: certs.keyfile,
        sni_fun: fn hostname ->
          send(owner, {:sni, hostname})
          []
        end
      ])

    {:ok, {_, port}} = :ssl.sockname(listener)
    on_exit(fn -> :ssl.close(listener) end)

    task =
      Task.async(fn ->
        {:ok, socket} = :ssl.transport_accept(listener, 2_000)

        case :ssl.handshake(socket, 2_000) do
          {:ok, socket} ->
            {:ok, request} = :ssl.recv(socket, 0, 2_000)
            :ssl.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 6\r\n\r\nsigned")
            :ssl.close(socket)
            request

          {:error, _} = error ->
            error
        end
      end)

    {listener, port, task}
  end
end

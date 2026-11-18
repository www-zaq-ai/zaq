defmodule Zaq.Channels.HttpClient.ReviewRegressionTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Zaq.Channels.HttpClient.{Connection, Pool, Transport}
  alias Zaq.Channels.HttpClient.Supervisor, as: HttpSupervisor
  alias Zaq.HttpRequest.AddressPolicy
  alias Zaq.System.OutboundHttpPolicy
  alias Zaq.TestSupport.Http2ResponsePeer

  @manager __MODULE__.Manager
  @connections __MODULE__.Connections
  @runtime __MODULE__.Runtime
  @url "http://127.0.0.1:1/"

  setup do
    start_supervised!({DynamicSupervisor, name: @runtime, strategy: :one_for_one})
    :ok = HttpSupervisor.ensure_started(runtime_options())
    :ok
  end

  test "the complete fe80::/10 range is denied, independently of the second hextet" do
    for ip <- ["fe80:400::1", "fe80:ffff::1", "fe81::1", "febf:ffff::1"] do
      assert {:ok, address} = AddressPolicy.parse_ip(ip)

      assert {:error, :blocked_link_local, _} =
               AddressPolicy.validate(address, %OutboundHttpPolicy{})
    end

    for ip <- ["fe7f:ffff::1", "fec0::1"] do
      assert {:ok, address} = AddressPolicy.parse_ip(ip)
      assert :ok = AddressPolicy.validate(address, %OutboundHttpPolicy{})
    end
  end

  property "every address in the IPv6 link-local prefix is blocked" do
    check all(
            first <- integer(0xFE80..0xFEBF),
            rest <- list_of(integer(0..0xFFFF), length: 7)
          ) do
      ip = List.to_tuple([first | rest])
      assert {:error, :blocked_link_local, _} = AddressPolicy.validate(ip, %OutboundHttpPolicy{})
    end
  end

  test "a queued acquisition expires without running its callback after the manager resumes" do
    owner = self()
    :ok = :sys.suspend(@manager)

    try do
      borrower =
        Task.async(fn ->
          Pool.with_pool(
            @url,
            [conn_opts: [transport_opts: [timeout: 50]]],
            fn _ ->
              send(owner, :late_send)
              :sent
            end,
            @manager
          )
        end)

      result = Task.yield(borrower, 500)
      :ok = :sys.resume(@manager)
      if is_nil(result), do: Task.await(borrower, 2_000)
      assert {:ok, {:error, %Req.TransportError{reason: :timeout}}} = result
      refute_received :late_send
    after
      if Process.whereis(@manager), do: :sys.resume(@manager)
    end
  end

  test "a leased request cannot execute against a replacement transport instance" do
    owner = self()

    borrower =
      Task.async(fn ->
        Pool.with_pool(
          @url,
          [],
          fn _ ->
            send(owner, {:leased, self()})

            receive do
              :continue -> :executed_after_restart
            end
          end,
          @manager
        )
      end)

    assert_receive {:leased, execution}, 2_000
    [{_, root, :supervisor, [HttpSupervisor]}] = DynamicSupervisor.which_children(@runtime)
    :ok = DynamicSupervisor.terminate_child(@runtime, root)
    :ok = HttpSupervisor.ensure_started(runtime_options())
    send(execution, :continue)
    assert {:error, %Req.TransportError{reason: :closed}} = Task.await(borrower, 2_000)
  end

  test "HTTP2 connection refusal is returned as the original error" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    :gen_tcp.close(listener)

    assert {:error, %Req.TransportError{reason: :econnrefused}} =
             Transport.request(
               [
                 url: "http://127.0.0.1:#{port}/",
                 receive_timeout: 1_000,
                 retry: false,
                 redirect: false,
                 connect_options: [protocols: [:http2]]
               ],
               [{127, 0, 0, 1}]
             )
  end

  test "HTTP2 refused IPv6 falls back to an approved IPv4 peer before sending" do
    url = Http2ResponsePeer.start!(["signed"], self(), capture_headers: true)

    assert {:ok, %{body: "signed"}} =
             Transport.request(
               [
                 url: url,
                 receive_timeout: 1_000,
                 retry: false,
                 redirect: false,
                 connect_options: [protocols: [:http2]]
               ],
               [{0, 0, 0, 0, 0, 0, 0, 1}, {127, 0, 0, 1}]
             )

    assert_receive {:http2_request_headers, _}
  end

  test "response reception retains its receive timeout after establishment completes" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    owner = self()

    peer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)
        {:ok, _} = :gen_tcp.recv(socket, 0, 2_000)
        send(owner, {:http_sent, self()})

        receive do
          :respond -> :ok
        end

        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 6\r\n\r\nsigned")
        :gen_tcp.close(socket)
      end)

    request =
      Task.async(fn ->
        Transport.request(
          [
            url: "http://localhost:#{port}/",
            receive_timeout: 1_000,
            retry: false,
            redirect: false
          ],
          [{127, 0, 0, 1}],
          deadline: System.monotonic_time(:millisecond) + 150
        )
      end)

    assert_receive {:http_sent, execution}, 2_000
    Process.send_after(execution, :respond, 200)
    assert {:ok, %{body: "signed"}} = Task.await(request, 2_000)
    Task.await(peer, 2_000)
  end

  @tag :tmp_dir
  test "restart during TLS establishment closes the original worker without HTTP bytes", %{
    tmp_dir: directory
  } do
    certs = Zaq.WidgetTLSFixtures.certificates(directory, subject_alt_name: "IP:127.0.0.1")
    {listener, port, peer} = gated_tls_peer(certs)

    request =
      Req.new(
        url: "https://localhost:#{port}/",
        connect_options: [transport_opts: [cacertfile: certs.cacertfile]]
      )

    borrower =
      Task.async(fn ->
        Pool.with_pool(
          "https://localhost:#{port}/",
          [],
          fn lease ->
            Connection.request(
              request,
              {127, 0, 0, 1},
              System.monotonic_time(:millisecond) + 2_000,
              lease[:send_started]
            )
          end,
          @manager
        )
      end)

    assert_receive {:tls_identity, ~c"localhost", gate}, 2_000
    [{_, root, :supervisor, [HttpSupervisor]}] = DynamicSupervisor.which_children(@runtime)
    :ok = DynamicSupervisor.terminate_child(@runtime, root)
    :ok = HttpSupervisor.ensure_started(runtime_options())
    send(gate, :finish_tls)

    assert {:error, %Req.TransportError{reason: :closed}} = Task.await(borrower, 2_000)
    assert {:error, _} = Task.await(peer, 2_000)
    assert {:error, :timeout} = :ssl.transport_accept(listener, 0)
  end

  @tag :tmp_dir
  test "expiration during TLS establishment cannot send HTTP after the handshake", %{
    tmp_dir: directory
  } do
    certs = Zaq.WidgetTLSFixtures.certificates(directory)
    {_listener, port, peer} = gated_tls_peer(certs)

    request =
      Req.new(
        url: "https://localhost:#{port}/",
        connect_options: [transport_opts: [cacertfile: certs.cacertfile]]
      )

    deadline = System.monotonic_time(:millisecond) + 150

    borrower =
      Task.async(fn ->
        Pool.with_pool(
          "https://localhost:#{port}/",
          [deadline: deadline],
          fn lease ->
            Connection.request(request, {127, 0, 0, 1}, deadline, lease[:send_started])
          end,
          @manager
        )
      end)

    assert_receive {:tls_identity, ~c"localhost", gate}, 2_000
    assert {:error, %Req.TransportError{reason: :timeout}} = Task.await(borrower, 2_000)
    send(gate, :finish_tls)
    assert {:error, _} = Task.await(peer, 2_000)
  end

  @tag :tmp_dir
  test "HTTP2 certificate mismatch returns the TLS error without a second handshake", %{
    tmp_dir: directory
  } do
    certs = Zaq.WidgetTLSFixtures.certificates(directory)
    owner = self()

    {:ok, listener} =
      :ssl.listen(0, [
        :binary,
        active: false,
        ip: {127, 0, 0, 1},
        certfile: certs.certfile,
        keyfile: certs.keyfile,
        alpn_preferred_protocols: ["h2"]
      ])

    {:ok, {_, port}} = :ssl.sockname(listener)
    on_exit(fn -> :ssl.close(listener) end)
    start_supervised!({Task, fn -> handshake_attempts(listener, owner, 1) end})

    assert {:error, %Req.TransportError{reason: {:tls_alert, _}}} =
             Transport.request(
               [
                 url: "https://mismatch.invalid:#{port}/",
                 receive_timeout: 1_500,
                 retry: false,
                 redirect: false,
                 connect_options: [
                   protocols: [:http2],
                   transport_opts: [cacertfile: certs.cacertfile]
                 ]
               ],
               [{127, 0, 0, 1}]
             )

    assert_receive {:handshake_attempt, 1}, 2_000
    refute_receive {:handshake_attempt, 2}, 650
  end

  @tag :tmp_dir
  test "an expired acquisition cannot start a TLS request", %{tmp_dir: directory} do
    certs = Zaq.WidgetTLSFixtures.certificates(directory)
    owner = self()

    {:ok, listener} =
      :ssl.listen(0, [
        :binary,
        active: false,
        ip: {127, 0, 0, 1},
        certfile: certs.certfile,
        keyfile: certs.keyfile
      ])

    {:ok, {_, port}} = :ssl.sockname(listener)
    on_exit(fn -> :ssl.close(listener) end)
    :ok = :sys.suspend(@manager)

    try do
      request =
        Task.async(fn ->
          Pool.with_pool(
            "https://localhost:#{port}/",
            [conn_opts: [transport_opts: [timeout: 50]]],
            fn _ ->
              send(owner, :late_http_callback)
              :sent
            end,
            @manager
          )
        end)

      result = Task.yield(request, 500)
      :ok = :sys.resume(@manager)
      if is_nil(result), do: Task.await(request, 2_000)
      assert {:ok, {:error, %Req.TransportError{reason: :timeout}}} = result
      refute_received :late_http_callback
      assert {:error, :timeout} = :ssl.transport_accept(listener, 0)
    after
      if Process.whereis(@manager), do: :sys.resume(@manager)
    end
  end

  defp handshake_attempts(listener, owner, attempt) do
    case :ssl.transport_accept(listener, 2_000) do
      {:ok, socket} ->
        send(owner, {:handshake_attempt, attempt})
        :ssl.handshake(socket, 2_000)
        :ssl.close(socket)
        handshake_attempts(listener, owner, attempt + 1)

      {:error, _} ->
        :ok
    end
  end

  defp gated_tls_peer(certs) do
    owner = self()
    gate = :atomics.new(1, [])

    {:ok, listener} =
      :ssl.listen(0, [
        :binary,
        active: false,
        ip: {127, 0, 0, 1},
        certfile: certs.certfile,
        keyfile: certs.keyfile,
        sni_fun: fn hostname ->
          if :atomics.add_get(gate, 1, 1) == 1 do
            send(owner, {:tls_identity, hostname, self()})

            receive do
              :finish_tls -> :ok
            after
              2_000 -> :ok
            end
          end

          []
        end
      ])

    {:ok, {_, port}} = :ssl.sockname(listener)
    on_exit(fn -> :ssl.close(listener) end)

    peer =
      Task.async(fn ->
        {:ok, socket} = :ssl.transport_accept(listener, 2_000)

        result =
          case :ssl.handshake(socket, 2_000) do
            {:ok, socket} -> :ssl.recv(socket, 0, 500)
            {:error, _} = error -> error
          end

        :ssl.close(socket, 0)
        result
      end)

    {listener, port, peer}
  end

  defp runtime_options do
    [
      runtime: @runtime,
      supervisor: __MODULE__.Supervisor,
      name: @manager,
      connections: @connections,
      capacity: 1
    ]
  end
end

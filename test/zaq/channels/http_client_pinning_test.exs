defmodule Zaq.Channels.HttpClient.PinningTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.HttpClient
  alias Zaq.Channels.HttpClient.Transport
  alias Zaq.HttpRequest.Prepared
  alias Zaq.System.OutboundHttpPolicy
  alias Zaq.TestSupport.Http2ResponsePeer

  test "literal IPv6 connects directly and preserves bracketed authority" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:inet6, :binary, active: false, ip: {0, 0, 0, 0, 0, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    peer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)
        {:ok, request} = :gen_tcp.recv(socket, 0, 2_000)
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
        :gen_tcp.close(socket)
        request
      end)

    url = "http://[::1]:#{port}/"

    assert {:ok, _} =
             HttpClient.request(prepared(url, %OutboundHttpPolicy{block_loopback: false}),
               lookup: fn _, _ -> flunk("literal IP must not resolve DNS") end
             )

    assert Task.await(peer) =~ "host: [::1]:#{port}\r\n"
  end

  test "HTTP2 authority retains the original hostname and port" do
    url = Http2ResponsePeer.start!(["signed"], self(), capture_headers: true)
    uri = URI.parse(url)

    options = [
      url: URI.to_string(%{uri | host: "authority.invalid"}),
      receive_timeout: 1_000,
      retry: false,
      redirect: false,
      connect_options: [protocols: [:http2]]
    ]

    assert {:ok, %{body: "signed"}} =
             Transport.request(options, [{127, 0, 0, 1}])

    assert_receive {:http2_request_headers, headers}
    assert {":authority", "authority.invalid:#{uri.port}"} in headers
  end

  test "a received POST is never replayed after a connection closes without a response" do
    {listener, port} = listen()

    {:ok, second} =
      :gen_tcp.listen(port, [
        :inet6,
        :binary,
        active: false,
        ipv6_v6only: true,
        ip: {0, 0, 0, 0, 0, 0, 0, 1}
      ])

    on_exit(fn -> :gen_tcp.close(second) end)

    peer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)
        {:ok, request} = :gen_tcp.recv(socket, 0, 2_000)
        :gen_tcp.close(socket)
        request
      end)

    options = [
      method: :post,
      body: "do-once",
      url: "http://localhost:#{port}/",
      receive_timeout: 1_000,
      redirect: false,
      retry: false
    ]

    assert {:error, _} =
             Transport.request(options, [
               {127, 0, 0, 1},
               {0, 0, 0, 0, 0, 0, 0, 1}
             ])

    assert Task.await(peer) =~ "POST / HTTP/1.1"
    assert {:error, :timeout} = :gen_tcp.accept(second, 0)
  end

  test "completed requests close their sockets and a changed policy cannot reuse an old peer" do
    {listener, port} = listen()

    peer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
        :gen_tcp.recv(socket, 0, 2_000)
      end)

    url = "http://localhost:#{port}/"
    lookup = fn _, family -> if family == :inet, do: {:ok, [{127, 0, 0, 1}]}, else: {:ok, []} end
    policy = %OutboundHttpPolicy{block_loopback: false}
    assert {:ok, _} = HttpClient.request(prepared(url, policy), lookup: lookup)
    assert Task.await(peer) == {:error, :closed}

    assert {:error, :ip_blacklisted, _} =
             HttpClient.request(prepared(url, %{policy | blacklisted_ips: ["127.0.0.1"]}),
               lookup: lookup
             )

    assert {:error, :timeout} = :gen_tcp.accept(listener, 0)
  end

  test "a public validation answer followed by a loopback answer cannot contact a local peer" do
    {listener, port} = listen()

    lookup = fn
      _, :inet -> {:ok, [{8, 8, 8, 8}]}
      _, :inet6 -> {:ok, [{0, 0, 0, 0, 0, 0, 0, 1}]}
    end

    assert {:error, :blocked_loopback, _} =
             HttpClient.request(prepared("http://localhost:#{port}/", %OutboundHttpPolicy{}),
               lookup: lookup
             )

    assert {:error, :timeout} = :gen_tcp.accept(listener, 0)
  end

  test "approved IPv6 failure falls back to approved IPv4 before sending a request" do
    {listener, port} = listen()

    peer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)
        {:ok, request} = :gen_tcp.recv(socket, 0, 2_000)
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
        :gen_tcp.close(socket)
        request
      end)

    options = [
      url: "http://localhost:#{port}/",
      receive_timeout: 1_000,
      redirect: false,
      retry: false
    ]

    assert {:ok, %{status: 200}} =
             Transport.request(options, [
               {0, 0, 0, 0, 0, 0, 0, 1},
               {127, 0, 0, 1}
             ])

    assert Task.await(peer) =~ "GET / HTTP/1.1"
  end

  test "a second hostname resolution cannot reach a blacklisted loopback peer" do
    {listener, port} = listen()
    policy = %OutboundHttpPolicy{block_loopback: false, blacklisted_ips: ["127.0.0.1"]}
    lookup = fn _, family -> if family == :inet, do: {:ok, [{127, 0, 0, 2}]}, else: {:ok, []} end

    # The OS resolves localhost to the forbidden listener. The approved snapshot
    # points elsewhere, so the inherited hostname-based transport reaches it.
    peer =
      Task.async(fn ->
        case :gen_tcp.accept(listener, 1_000) do
          {:ok, socket} ->
            :gen_tcp.recv(socket, 0, 1_000)
            :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
            :gen_tcp.close(socket)
            :forbidden_peer_reached

          {:error, :closed} ->
            :not_reached

          {:error, :timeout} ->
            :not_reached
        end
      end)

    result = HttpClient.request(prepared("http://localhost:#{port}/", policy), lookup: lookup)
    :gen_tcp.close(listener)
    assert Task.await(peer) == :not_reached
    assert {:error, _} = result
  end

  test "both response modes connect to the approved peer and preserve the original Host" do
    for format <- ["decoded", "raw"] do
      {listener, port} = listen()

      peer =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 2_000)
          {:ok, request} = :gen_tcp.recv(socket, 0, 2_000)

          :ok =
            :gen_tcp.send(
              socket,
              "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 12\r\n\r\n{\"value\": 1}"
            )

          :gen_tcp.close(socket)
          request
        end)

      url = "http://unresolvable.invalid:#{port}/signed?original=1"
      policy = %OutboundHttpPolicy{block_loopback: false}

      lookup = fn _, family ->
        if family == :inet, do: {:ok, [{127, 0, 0, 1}]}, else: {:ok, []}
      end

      assert {:ok, response} =
               HttpClient.request(%{prepared(url, policy) | response_format: format},
                 lookup: lookup
               )

      assert response.url == url
      assert Task.await(peer) =~ "host: unresolvable.invalid:#{port}\r\n"

      if format == "raw",
        do: assert(Base.decode64!(response.body) == "{\"value\": 1}"),
        else: assert(response.body == %{"value" => 1})
    end
  end

  defp listen do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    {listener, port}
  end

  defp prepared(url, policy) do
    %Prepared{
      method: "GET",
      url: url,
      uri: URI.parse(url),
      headers: %{},
      query: %{},
      body_format: "json",
      timeout_ms: 1_000,
      doc_reference: "",
      policy: policy
    }
  end
end

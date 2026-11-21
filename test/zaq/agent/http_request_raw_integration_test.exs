defmodule Zaq.Agent.HttpRequestRawIntegrationTest do
  use Zaq.DataCase, async: true, group: :req_default_options
  use ExUnitProperties

  alias Zaq.Agent.Tools.Registry
  alias Zaq.Engine.Connect
  alias Zaq.Event
  alias Zaq.HttpRequest
  alias Zaq.NodeRouter
  alias Zaq.System, as: ZaqSystem
  alias Zaq.System.{HttpCredentialProviderRef, OutboundHttpPolicy}
  alias Zaq.TestSupport.{Http2ResponsePeer, HTTPFixtureOptions}

  @limit 128

  setup do
    Process.put({__MODULE__, :reference}, Ecto.UUID.generate())
    :ok
  end

  test "raw non-2xx responses preserve compressed entity bytes and filtered duplicate headers" do
    entity = :zlib.gzip(<<0, 255, 128, "signed-response">>)

    url =
      peer(fn socket ->
        :gen_tcp.send(socket, [
          "HTTP/1.1 422 Unprocessable Content\r\n",
          "content-type: application/json\r\ncontent-encoding: gzip\r\n",
          "signature: first\r\nsignature: second\r\n",
          "set-cookie: private-cookie\r\nauthorization: private-auth\r\n",
          "proxy-authorization: private-proxy\r\n",
          "content-length: #{byte_size(entity)}\r\nconnection: close\r\n\r\n",
          entity
        ])
      end)

    assert {:ok, response} =
             execute(url, %{response_format: "raw", headers: %{"accept-encoding" => "gzip"}})

    assert response.status == 422
    refute response.success
    refute response.truncated
    assert response.body_encoding == "base64"
    assert Base.decode64!(response.body) == entity
    assert response.headers["content-encoding"] == ["gzip"]
    assert response.headers["signature"] == ["first", "second"]
    refute Map.has_key?(response.headers, "set-cookie")
    refute Map.has_key?(response.headers, "authorization")
    refute Map.has_key?(response.headers, "proxy-authorization")
    assert Jason.decode!(Jason.encode!(response))["body"] == Base.encode64(entity)
    assert_receive {:request_headers, headers}
    assert {"accept-encoding", "identity"} in headers
  end

  test "chunked overflow closes reception before the peer finishes, including error statuses" do
    owner = self()

    for status <- [200, 503] do
      url =
        peer(fn socket ->
          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 #{status} Response\r\ntransfer-encoding: chunked\r\n\r\n",
              chunk(String.duplicate("a", @limit)),
              chunk("b")
            ])

          send(owner, {:reception_ended, :gen_tcp.recv(socket, 0, 2_000)})
        end)

      assert {:error, reason} = execute(url, %{response_format: "raw"})
      assert inspect(reason) =~ "response_too_large"
      assert_receive {:reception_ended, {:error, :closed}}, 3_000
    end
  end

  test "raw JSON keeps signed whitespace through credential preparation and does not follow redirects" do
    entity = "{\n  \"value\": 1, \"value\": 2\n}\n"
    credential = header_credential()

    for status <- [200, 307] do
      url =
        peer(fn socket ->
          :gen_tcp.send(socket, [
            "HTTP/1.1 #{status} Response\r\ncontent-type: application/json\r\n",
            "location: https://must-not-follow.invalid/\r\n",
            "content-length: #{byte_size(entity)}\r\n\r\n",
            entity
          ])
        end)

      assert {:ok, response} =
               execute(url, %{response_format: "raw", credential_id: credential.id})

      assert response.status == status
      assert Base.decode64!(response.body) == entity
      assert_receive {:request_headers, headers}
      assert {"x-http-key", "stored-http-credential-sentinel"} in headers
      refute inspect(response) =~ "stored-http-credential-sentinel"

      assert {:error, error} =
               execute(String.replace(url, "127.0.0.1", "localhost"), %{
                 response_format: "raw",
                 credential_id: credential.id
               })

      assert inspect(error) =~ "credential_host_not_allowed"
    end
  end

  test "raw format is validated both at the Action boundary and during Engine revalidation" do
    params = %{method: "GET", url: "http://127.0.0.1:1"}
    assert {:ok, request} = HttpRequest.build(params)
    assert {:ok, [action]} = Registry.resolve_modules(["general.http_request"])

    assert {:ok, _} =
             %OutboundHttpPolicy{}
             |> OutboundHttpPolicy.changeset(%{enabled: true, allowed_ports: [1]})
             |> ZaqSystem.save_outbound_http_policy()

    for invalid <- [nil, false, "RAW", "unsupported"] do
      if invalid != nil do
        assert {:error, _} = action.validate_params(Map.put(params, :response_format, invalid))
      end

      assert {:error, "response_format must be decoded or raw"} =
               HttpRequest.build(Map.put(params, :response_format, invalid))

      assert %{response: {:error, :invalid_response_format, _}} =
               %{request: %{request | response_format: invalid}}
               |> Event.new(:channels, opts: [action: :http_request, confidential: true])
               |> NodeRouter.dispatch()
    end
  end

  test "raw response headers cannot make an otherwise binary-safe result invalid JSON" do
    url =
      peer(fn socket ->
        :gen_tcp.send(socket, [
          "HTTP/1.1 200 OK\r\nx-metadata: ",
          <<255>>,
          "\r\ncontent-length: 2\r\n\r\nok"
        ])
      end)

    assert {:error, error} = execute(url, %{response_format: "raw"})
    assert inspect(error) =~ "invalid_response_headers"
  end

  test "raw HTTP1 trailers preserve signing metadata separately from headers at the byte limit" do
    for {size, status} <- [{1, 200}, {@limit, 422}] do
      entity = :binary.copy(<<255>>, size)

      url =
        peer(fn socket ->
          :gen_tcp.send(socket, [
            "HTTP/1.1 #{status} Response\r\ntransfer-encoding: chunked\r\n",
            "signature: initial\r\ntrailer: signature, content-digest\r\n\r\n",
            chunk(entity),
            "0\r\nSignature: first\r\nSignature: second\r\ncontent-digest: sha-256=:digest:\r\n",
            "set-cookie: hidden\r\nauthorization: hidden\r\nproxy-authorization: hidden\r\n\r\n"
          ])
        end)

      assert {:ok, response} = execute(url, %{response_format: "raw"})
      assert response.status == status
      assert response.success == status in 200..299
      assert Base.decode64!(response.body) == entity
      refute response.truncated
      assert response.headers["signature"] == ["initial"]
      assert response.headers["trailer"] == ["signature, content-digest"]

      assert response.trailers == %{
               "signature" => ["first", "second"],
               "content-digest" => ["sha-256=:digest:"]
             }

      assert Jason.decode!(Jason.encode!(response))["trailers"] == response.trailers
    end
  end

  @tag skip:
         "Enable after Finch https://github.com/sneako/finch/issues/408 is fixed and updated (zaq-bjp)"
  test "empty chunked HTTP1 responses preserve initial headers separately from trailers" do
    url =
      peer(fn socket ->
        :gen_tcp.send(socket, [
          "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n",
          "signature: initial\r\ntrailer: signature\r\n\r\n",
          "0\r\nsignature: final\r\n\r\n"
        ])
      end)

    assert {:ok, response} = execute(url, %{response_format: "raw"})
    assert Base.decode64!(response.body) == ""
    assert response.headers["signature"] == ["initial"]
    assert response.headers["trailer"] == ["signature"]
    assert response.trailers == %{"signature" => ["final"]}
  end

  test "raw responses without trailers return an empty map and decoded responses omit it" do
    for format <- ["raw", "decoded"], entity <- ["", "ok"] do
      url =
        peer(
          &:gen_tcp.send(
            &1,
            "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(entity)}\r\n\r\n#{entity}"
          )
        )

      assert {:ok, response} = execute(url, %{response_format: format})

      if format == "raw",
        do: assert(response.trailers == %{}),
        else: refute(Map.has_key?(response, :trailers))
    end
  end

  test "invalid retained HTTP1 trailers fail before returning a JSON-unsafe response" do
    for confidential? <- [false, true] do
      url =
        peer(fn socket ->
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n",
            chunk("ok"),
            "0\r\nsignature: ",
            <<255>>,
            "\r\n\r\n"
          ])
        end)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, error} =
                 execute(url, %{response_format: "raw"}, %{
                   event_opts: [confidential: confidential?]
                 })

        if confidential? do
          assert error.message == "confidential_http_request_failed"
          assert error.details.reason == :invalid_response_headers
        else
          assert inspect(error) =~ "invalid_response_headers"
        end
      end)
    end
  end

  test "sensitive HTTP1 trailers are removed before UTF8 validation" do
    url =
      peer(fn socket ->
        :gen_tcp.send(socket, [
          "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n0\r\n",
          Enum.map(["set-cookie", "authorization", "proxy-authorization"], fn name ->
            [name, ": ", <<255>>, "\r\n"]
          end),
          "\r\n"
        ])
      end)

    assert {:ok, response} = execute(url, %{response_format: "raw"})
    assert response.trailers == %{}
    assert Base.decode64!(response.body) == ""
  end

  property "non-empty raw HTTP1 entities preserve ordered trailer metadata" do
    check all(
            entity <- binary(min_length: 1, max_length: @limit),
            values <-
              list_of(string(:alphanumeric, min_length: 1, max_length: 16),
                min_length: 1,
                max_length: 4
              ),
            max_runs: 12
          ) do
      url =
        peer(fn socket ->
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n",
            chunk(entity),
            "0\r\n",
            Enum.map(values, &["signature: ", &1, "\r\n"]),
            "\r\n"
          ])
        end)

      assert {:ok, response} = execute(url, %{response_format: "raw"})
      assert response.trailers == %{"signature" => values}
      assert Base.decode64!(response.body) == entity
      refute response.truncated
    end
  end

  test "HTTP1 trailers do not turn oversized or incomplete responses into partial success" do
    url =
      peer(fn socket ->
        :gen_tcp.send(socket, [
          "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n",
          chunk(String.duplicate("x", @limit + 1)),
          "0\r\nsignature: final\r\n\r\n"
        ])
      end)

    assert {:error, error} = execute(url, %{response_format: "raw"})
    assert inspect(error) =~ "response_too_large"

    for incomplete <- ["0\r\nsignature:", "0\r\nsignature: incomplete\r\n"] do
      url =
        peer(fn socket ->
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n",
            chunk("complete entity"),
            incomplete
          ])
        end)

      assert {:error, error} = execute(url, %{response_format: "raw"})
      assert inspect(error) =~ "transport_error"
    end
  end

  test "HTTP2 trailing HEADERS preserve filtered duplicate metadata and exact entity bytes" do
    for size <- [0, @limit] do
      entity = :binary.copy(<<255>>, size)

      url =
        Http2ResponsePeer.start!([entity], self(),
          headers: [{"signature", "initial"}],
          trailers: [
            {"signature", "first"},
            {"signature", "second"},
            {"content-digest", "sha-256=:digest:"},
            {"set-cookie", "hidden"},
            {"authorization", "hidden"},
            {"proxy-authorization", "hidden"}
          ]
        )

      save_policy(url)
      HTTPFixtureOptions.configure(url, connect_options: [protocols: [:http2]])
      assert {:ok, response} = execute(url, %{response_format: "raw"})
      assert response.headers["signature"] == ["initial"]

      assert response.trailers == %{
               "signature" => ["first", "second"],
               "content-digest" => ["sha-256=:digest:"]
             }

      assert Base.decode64!(response.body) == entity
      refute response.truncated
      assert_receive {:http2_response_sent, peer}
      send(peer, :close)
    end
  end

  test "HTTP2 trailers reject retained invalid UTF8 and ignore invalid redacted fields" do
    for field <- ["signature", "set-cookie"] do
      url = Http2ResponsePeer.start!(["ok"], self(), trailers: [{field, <<255>>}])
      save_policy(url)
      HTTPFixtureOptions.configure(url, connect_options: [protocols: [:http2]])

      if field == "signature" do
        assert {:error, error} = execute(url, %{response_format: "raw"})
        assert inspect(error) =~ "invalid_response_headers"
      else
        assert {:ok, response} = execute(url, %{response_format: "raw"})
        assert response.trailers == %{}
        assert Base.decode64!(response.body) == "ok"
      end

      assert_receive {:http2_response_sent, peer}
      send(peer, :close)
    end
  end

  test "HTTP2 trailing metadata without END_STREAM is not a complete response" do
    url =
      Http2ResponsePeer.start!(["complete entity"], self(),
        trailers: [{"signature", "incomplete"}],
        end_stream: false
      )

    save_policy(url)
    HTTPFixtureOptions.configure(url, connect_options: [protocols: [:http2]])
    assert {:error, error} = execute(url, %{response_format: "raw"})
    assert inspect(error) =~ "transport_error"
  end

  property "raw chunked entity bytes round-trip exactly up to the configured bound" do
    check all(entity <- binary(max_length: @limit), max_runs: 12) do
      url =
        peer(fn socket ->
          split = div(byte_size(entity), 2)
          <<first::binary-size(^split), last::binary>> = entity

          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n",
            chunk(first),
            chunk(last),
            "0\r\n\r\n"
          ])
        end)

      assert {:ok, response} = execute(url, %{response_format: "raw"})
      assert response.body_encoding == "base64"
      assert Base.decode64!(response.body) == entity
      refute response.truncated
    end
  end

  test "exact limit succeeds and oversized Content-Length bodies fail without truncated success" do
    for size <- [0, @limit, @limit + 1] do
      entity = :binary.copy(<<255>>, size)

      url =
        peer(fn socket ->
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\ncontent-length: #{size}\r\n\r\n",
            entity
          ])
        end)

      if size <= @limit do
        assert {:ok, response} = execute(url, %{response_format: "raw"})
        assert Base.decode64!(response.body) == entity
        refute response.truncated
      else
        assert {:error, reason} = execute(url, %{response_format: "raw"})
        assert inspect(reason) =~ "response_too_large"
      end
    end
  end

  test "HTTP2 empty DATA frames do not alter the entity or consume its exact byte allowance" do
    entity = :binary.copy(<<0, 255>>, div(@limit, 2))
    <<first::binary-size(64), last::binary>> = entity
    url = Http2ResponsePeer.start!(["", first, "", last, ""], self())
    save_policy(url)
    HTTPFixtureOptions.configure(url, connect_options: [protocols: [:http2]])

    assert {:ok, response} = execute(url, %{response_format: "raw"})
    assert response.status == 200
    assert response.body_encoding == "base64"
    assert Base.decode64!(response.body) == entity
    refute response.truncated
    assert_received {:http2_request, stream_id}
    assert stream_id > 0 and rem(stream_id, 2) == 1
    assert_receive {:http2_response_sent, peer}
    send(peer, :close)
  end

  test "disconnects in fixed-length and chunked bodies never return partial success" do
    for framing <- [
          "content-length: 40\r\n\r\npartial",
          "transfer-encoding: chunked\r\n\r\n9\r\npartial"
        ] do
      url = peer(&:gen_tcp.send(&1, "HTTP/1.1 200 OK\r\n" <> framing))
      assert {:error, reason} = execute(url, %{response_format: "raw"})
      assert inspect(reason) =~ "transport_error"
    end
  end

  test "decoded default retains JSON decoding, joined headers and truncation" do
    for {entity, content_type, expected, truncated} <- [
          {~s({"ok":true}), "application/json", %{"ok" => true}, false},
          {String.duplicate("x", @limit + 1), "text/plain", String.duplicate("x", @limit), true}
        ] do
      url =
        peer(fn socket ->
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\ncontent-type: #{content_type}\r\n",
            "x-meta: one\r\nx-meta: two\r\n",
            "content-length: #{byte_size(entity)}\r\n\r\n",
            entity
          ])
        end)

      assert {:ok, response} = execute(url)
      assert response.body == expected
      assert response.truncated == truncated
      assert response.headers["x-meta"] == "one, two"
      refute Map.has_key?(response, :body_encoding)
    end
  end

  test "trusted confidentiality suppresses both HTTP dispatch hops and payload-bearing logs" do
    :ok = Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")
    sentinel = "private-http-payload-sentinel"

    url =
      peer(fn socket ->
        :gen_tcp.send(socket, [
          "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(sentinel)}\r\n\r\n",
          sentinel
        ])
      end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, response} =
                 execute(
                   url,
                   %{response_format: "raw", query: %{"payload" => sentinel}},
                   %{event_opts: [confidential: true]}
                 )

        assert Base.decode64!(response.body) == sentinel
      end)

    refute_http_events()
    refute log =~ sentinel
    refute log =~ Base.encode64(sentinel)
  end

  test "caller parameters cannot make either HTTP hop confidential" do
    :ok = Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")
    url = peer(&:gen_tcp.send(&1, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok"))

    assert {:ok, _} =
             execute(url, %{confidential: true, event_opts: [confidential: true]})

    reference = Process.get({__MODULE__, :reference})

    assert_received {:node_router_event,
                     %{
                       request: %{request: %HttpRequest{doc_reference: ^reference}},
                       opts: outer_opts
                     }}

    assert outer_opts[:action] == :http_request
    refute outer_opts[:confidential]

    assert_received {:node_router_event,
                     %{request: %HttpRequest{doc_reference: ^reference}, opts: child_opts}}

    assert child_opts[:action] == :prepare_http_request
    refute child_opts[:confidential]
    refute_http_events()
  end

  test "confidential preparation failures become safe errors before Jido logs them" do
    :ok = Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")
    sentinel = "private-http-host-sentinel.example"

    assert {:ok, _} =
             %OutboundHttpPolicy{}
             |> OutboundHttpPolicy.changeset(%{enabled: true, blacklisted_hosts: [sentinel]})
             |> ZaqSystem.save_outbound_http_policy()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, %Jido.Action.Error.ExecutionFailureError{} = error} =
                 execute(
                   "https://#{sentinel}/signed",
                   %{response_format: "raw"},
                   %{event_opts: [confidential: true]}
                 )

        assert error.message == "confidential_http_request_failed"
        assert error.details.retry == false
        refute inspect(error) =~ sentinel
      end)

    refute log =~ sentinel
    refute_http_events()
  end

  test "confidential validation, overflow and disconnect errors expose only safe classifications" do
    :ok = Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")
    sentinel = "private-http-failure-sentinel"

    for failure <- [:validation, :response_too_large, :transport_error] do
      url =
        case failure do
          :validation ->
            "https://example.com/?payload=#{sentinel}"

          reason ->
            peer(fn socket ->
              entity =
                if reason == :response_too_large,
                  do: String.duplicate(sentinel, 8),
                  else: sentinel

              declared_size = if reason == :response_too_large, do: byte_size(entity), else: 100

              :gen_tcp.send(socket, [
                "HTTP/1.1 500 Failure\r\ncontent-length: #{declared_size}\r\n\r\n",
                entity
              ])
            end)
        end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, %Jido.Action.Error.ExecutionFailureError{} = error} =
                   execute(url, %{response_format: "raw"}, %{event_opts: [confidential: true]})

          assert error.message == "confidential_http_request_failed"
          assert error.details.retry == false

          if failure == :validation,
            do: assert(error.details.phase == :validation),
            else: assert(error.details.reason == failure)

          refute inspect(error) =~ sentinel
        end)

      assert log =~ "confidential request failed"
      refute log =~ sentinel
      refute log =~ Base.encode64(sentinel)
      refute_http_events()
    end
  end

  defp header_credential do
    {:ok, provider} =
      ZaqSystem.create_http_credential_provider(%{
        name: "Raw HTTP provider",
        auth_kind: "api_key",
        placement: "header",
        parameter_name: "x-http-key",
        host_patterns: ["127.0.0.1"],
        enabled: true
      })

    {:ok, provider_ref} = HttpCredentialProviderRef.format(provider.id)

    {:ok, credential} =
      Connect.create_credential(%{
        name: "Raw HTTP credential",
        provider: provider_ref,
        auth_kind: "api_key",
        request_format: "raw",
        user_level: false,
        metadata: %{},
        api_key: "stored-http-credential-sentinel"
      })

    credential
  end

  defp execute(url, params \\ %{}, context \\ %{}) do
    assert {:ok, [action]} = Registry.resolve_modules(["general.http_request"])
    params = Map.put(params, :doc_reference, Process.get({__MODULE__, :reference}))

    Jido.Exec.run(action, Map.merge(%{method: "GET", url: url}, params), context,
      timeout: 0,
      max_retries: 0
    )
  end

  defp refute_http_events do
    reference = Process.get({__MODULE__, :reference})

    refute_received {:node_router_event,
                     %{request: %{request: %HttpRequest{doc_reference: ^reference}}}}

    refute_received {:node_router_event, %{request: %HttpRequest{doc_reference: ^reference}}}
  end

  defp peer(respond) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    owner = self()
    on_exit(fn -> :gen_tcp.close(listener) end)

    start_supervised!(
      {Task,
       fn ->
         {:ok, socket} = :gen_tcp.accept(listener, 5_000)
         {:ok, {:http_request, _, _, _}} = :gen_tcp.recv(socket, 0, 5_000)
         send(owner, {:request_headers, receive_headers(socket, [])})
         :ok = :inet.setopts(socket, packet: :raw)
         respond.(socket)
         :gen_tcp.close(socket)
       end},
      id: make_ref()
    )

    url = "http://127.0.0.1:#{port}/signed"
    save_policy(url)
    url
  end

  defp save_policy(url) do
    assert {:ok, _} =
             %OutboundHttpPolicy{}
             |> OutboundHttpPolicy.changeset(%{
               enabled: true,
               block_loopback: false,
               allowed_methods: ["GET"],
               allowed_ports: [URI.parse(url).port],
               max_response_bytes: @limit
             })
             |> ZaqSystem.save_outbound_http_policy()
  end

  defp receive_headers(socket, headers) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, :http_eoh} ->
        Enum.reverse(headers)

      {:ok, {:http_header, _, name, _, value}} ->
        receive_headers(socket, [{name |> to_string() |> String.downcase(), value} | headers])
    end
  end

  defp chunk(""), do: ""
  defp chunk(bytes), do: [Integer.to_string(byte_size(bytes), 16), "\r\n", bytes, "\r\n"]
end

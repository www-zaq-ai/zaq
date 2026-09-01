defmodule Zaq.Channels.HttpClientTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.HttpClient, as: Client
  alias Zaq.HttpRequest
  alias Zaq.System.OutboundHttpPolicy

  defmodule ConfigStub do
    def get(:zaq, Client, [], opts), do: Keyword.fetch!(opts, :http_client_config)
  end

  # Every test that should reach the "network" installs a Req.Test plug, which
  # stubs the transport. The production Channels.Api path never forwards event
  # options into this seam.
  defp stub(fun), do: test_opts(policy: policy(), resolver: resolver(), req_options: [plug: fun])

  defp stub_with(opts, extra) do
    Keyword.update!(opts, :http_client_config, &Keyword.merge(&1, extra))
  end

  defp test_opts(config), do: [config: ConfigStub, http_client_config: config]

  # Response shapes a plug cannot produce (a nil header map, a non-encodable
  # body) are injected at the adapter seam instead.
  defp adapter(response),
    do:
      test_opts(
        policy: policy(),
        resolver: resolver(),
        req_options: [adapter: fn request -> {request, response} end]
      )

  defp policy(overrides \\ %{}) do
    struct!(
      OutboundHttpPolicy,
      Map.merge(
        %{enabled: true, allowed_methods: ~w(GET HEAD OPTIONS POST PUT PATCH DELETE)},
        overrides
      )
    )
  end

  defp resolver, do: fn _host, _family -> {:ok, [{93, 184, 216, 34}]} end

  # Fixtures go through `build/2` rather than being hand-written: the executor
  # accepts nothing else, and a hand-built struct would not prove the pipeline
  # agrees with itself.
  defp spec(overrides \\ %{}) do
    {:ok, request} =
      %{method: "GET", url: "https://api.acme.test/v1/things"}
      |> Map.merge(overrides)
      |> HttpRequest.build()

    request
  end

  describe "performing the request" do
    test "sends method, path, headers, and json body, and returns the response" do
      opts =
        stub(fn conn ->
          assert conn.method == "POST"
          assert conn.request_path == "/v1/things"
          assert Plug.Conn.get_req_header(conn, "x-trace") == ["abc"]

          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert Jason.decode!(body) == %{"sku" => "A1"}

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(201, ~s({"id":"thing_1"}))
        end)

      assert {:ok, response} =
               Client.request(
                 spec(%{
                   method: "POST",
                   headers: %{"x-trace" => "abc"},
                   body: %{"sku" => "A1"}
                 }),
                 opts
               )

      assert response.status == 201
      assert response.success
      assert response.body == %{"id" => "thing_1"}
      assert response.truncated == false
      assert response.url == "https://api.acme.test/v1/things"
    end

    test "sends query parameters" do
      opts =
        stub(fn conn ->
          assert conn.query_string == "page=2"
          Plug.Conn.resp(conn, 200, "ok")
        end)

      assert {:ok, %{status: 200}} = Client.request(spec(%{query: %{"page" => "2"}}), opts)
    end

    test "sends a form body and a raw body" do
      form =
        stub(fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert body == "a=b"
          Plug.Conn.resp(conn, 200, "ok")
        end)

      assert {:ok, _} =
               Client.request(
                 spec(%{method: "POST", body: %{"a" => "b"}, body_format: "form"}),
                 form
               )

      raw =
        stub(fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert body == "<xml/>"
          Plug.Conn.resp(conn, 200, "ok")
        end)

      assert {:ok, _} =
               Client.request(
                 spec(%{method: "POST", body: "<xml/>", body_format: "raw"}),
                 raw
               )
    end

    test "reports a non-2xx status without treating it as an error" do
      opts = stub(fn conn -> Plug.Conn.resp(conn, 422, ~s({"error":"nope"})) end)

      assert {:ok, %{status: 422, success: false}} = Client.request(spec(), opts)
    end

    test "surfaces a transport failure" do
      opts = stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, {:transport_error, _}} = Client.request(spec(), opts)
    end

    test "does not follow redirects" do
      opts =
        stub(fn conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "http://127.0.0.1/internal")
          |> Plug.Conn.resp(302, "")
        end)

      assert {:ok, %{status: 302}} = Client.request(spec(), opts)
    end

    test "the spec's timeout wins over the configured default" do
      opts = stub(fn conn -> Plug.Conn.resp(conn, 200, "ok") end)

      assert {:ok, _} =
               Client.request(
                 spec(%{timeout_ms: 1_234}),
                 stub_with(opts, timeout_ms: 30_000)
               )
    end

    test "protected transport options override injected test req options" do
      opts = stub(fn conn -> Plug.Conn.resp(conn, 200, "ok") end)

      opts =
        update_in(opts[:http_client_config][:req_options], fn req_options ->
          Keyword.merge(req_options,
            method: :post,
            url: "http://127.0.0.1/evil",
            redirect: true,
            retry: true
          )
        end)

      assert {:ok, %{status: 200, url: "https://api.acme.test/v1/things"}} =
               Client.request(spec(), opts)
    end
  end

  describe "refusing an unvalidated spec" do
    test "a bare map is validated at the execution boundary" do
      assert {:error, :invalid_method, _} =
               Client.request(
                 %{method: :get, url: "https://api.acme.test/v1/things"},
                 stub(fn c -> c end)
               )
    end

    test "a string-keyed map is validated and can execute" do
      assert {:ok, %{status: 200}} =
               Client.request(
                 %{"method" => "PUT", "url" => "https://api.acme.test/v1/things"},
                 stub(fn conn -> Plug.Conn.resp(conn, 200, "ok") end)
               )
    end

    test "boundary validation happens before any socket is opened" do
      assert {:error, :method_not_allowed, _} =
               Client.request(
                 %{"method" => "POST", "url" => "https://api.acme.test/x"},
                 stub_with(
                   stub(fn _conn ->
                     flunk("the executor opened a socket for a blocked request")
                   end),
                   policy: policy(%{allowed_methods: ["GET"]})
                 )
               )
    end

    test "a forged struct cannot bypass destination policy" do
      forged = %HttpRequest{method: :get, url: "http://127.0.0.1/internal", timeout_ms: 1_000}

      assert {:error, :blocked_loopback, _} = Client.request(forged, stub(fn c -> c end))
    end
  end

  describe "resolved destination validation" do
    test "passes the hostname as a charlist and resolves with inet" do
      resolver = fn host, family ->
        assert host == ~c"api.acme.test"
        assert family == :inet
        {:ok, []}
      end

      opts =
        test_opts(
          policy: policy(),
          resolver: resolver,
          req_options: [plug: fn _conn -> flunk("transport reached after DNS failure") end]
        )

      assert {:error, :dns_failed, "host resolved to no addresses"} =
               Client.request(spec(), opts)
    end

    test "blocks a loopback address when DNS returns mixed public and loopback addresses" do
      resolver = fn _host, _family -> {:ok, [{93, 184, 216, 34}, {127, 0, 0, 1}]} end

      opts =
        test_opts(
          policy: policy(),
          resolver: resolver,
          req_options: [plug: fn _conn -> flunk("transport reached for blocked loopback") end]
        )

      assert {:error, :blocked_loopback, _} = Client.request(spec(), opts)
    end

    test "normalizes resolver errors and does not open a transport" do
      resolver = fn _host, _family -> {:error, :nxdomain} end

      opts =
        test_opts(
          policy: policy(),
          resolver: resolver,
          req_options: [plug: fn _conn -> flunk("transport reached after resolver error") end]
        )

      assert {:error, :dns_failed, "could not resolve host"} = Client.request(spec(), opts)
    end
  end

  describe "response shaping" do
    test "truncates an oversized binary body and flags it" do
      opts = stub(fn conn -> Plug.Conn.resp(conn, 200, String.duplicate("x", 500)) end)

      assert {:ok, %{body: body, truncated: true}} =
               Client.request(spec(), stub_with(opts, policy: policy(%{max_response_bytes: 100})))

      assert byte_size(body) == 100
    end

    test "truncates an oversized json body into a string" do
      big = Jason.encode!(%{"items" => Enum.to_list(1..500)})

      opts =
        stub(fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, big)
        end)

      assert {:ok, %{body: body, truncated: true}} =
               Client.request(spec(), stub_with(opts, policy: policy(%{max_response_bytes: 50})))

      assert is_binary(body)
      assert byte_size(body) == 50
    end

    test "keeps a small body intact" do
      opts = stub(fn conn -> Plug.Conn.resp(conn, 200, "small") end)

      assert {:ok, %{body: "small", truncated: false}} = Client.request(spec(), opts)
    end

    test "passes through a body that is neither a binary nor a collection" do
      # JSON `null` decodes to nil, which no truncation clause can measure.
      opts =
        stub(fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, "null")
        end)

      assert {:ok, %{body: nil, truncated: false}} = Client.request(spec(), opts)
    end

    test "keeps an oversized json body whose encoding fails" do
      # A tuple cannot be JSON-encoded, so size is unknown and the body is kept.
      opts = adapter(%Req.Response{status: 200, headers: %{}, body: [{:a, 1}]})

      assert {:ok, %{body: [{:a, 1}], truncated: false}} =
               Client.request(spec(), stub_with(opts, policy: policy(%{max_response_bytes: 1})))
    end

    test "stringifies a header value that is neither a list nor a binary" do
      opts = adapter(%Req.Response{status: 200, headers: %{"x-count" => 42}, body: "ok"})

      assert {:ok, %{headers: %{"x-count" => "42"}}} = Client.request(spec(), opts)
    end

    test "keeps a header value that arrived as a bare string" do
      opts = adapter(%Req.Response{status: 200, headers: %{"x-trace" => "abc"}, body: "ok"})

      assert {:ok, %{headers: %{"x-trace" => "abc"}}} = Client.request(spec(), opts)
    end

    test "lowercases response headers and drops sensitive ones" do
      opts =
        stub(fn conn ->
          conn
          |> Plug.Conn.put_resp_header("X-Rate-Limit", "10")
          |> Plug.Conn.put_resp_header("set-cookie", "session=secret")
          |> Plug.Conn.resp(200, "ok")
        end)

      assert {:ok, %{headers: headers}} = Client.request(spec(), opts)

      assert headers["x-rate-limit"] == "10"
      refute Map.has_key?(headers, "set-cookie")
    end
  end

  # Credential resolution needs the database, so it lives in
  # `Zaq.HttpRequest.SecretsTest` rather than here.
end

defmodule Zaq.Channels.HttpClientTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.HttpClient, as: Client
  alias Zaq.HttpRequest

  # Every test that should reach the "network" installs a Req.Test plug, which
  # stubs the transport. Destination policy is not exercised here — it is
  # enforced at build time and covered in `Zaq.HttpRequestTest`.
  defp stub(fun), do: [req_options: [plug: fun]]
  defp stub_with(opts, extra), do: Keyword.merge(opts, extra)

  # Response shapes a plug cannot produce (a nil header map, a non-encodable
  # body) are injected at the adapter seam instead.
  defp adapter(response), do: [req_options: [adapter: fn request -> {request, response} end]]

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
  end

  describe "refusing an unvalidated spec" do
    test "a bare map is refused rather than normalised" do
      assert {:error, {:invalid_request, :unvalidated_spec}} =
               Client.request(
                 %{method: :get, url: "https://api.acme.test/v1/things"},
                 stub(fn c -> c end)
               )
    end

    test "a string-keyed map is refused too — there is no rehydration here" do
      assert {:error, {:invalid_request, :unvalidated_spec}} =
               Client.request(
                 %{"method" => "PUT", "url" => "https://api.acme.test/v1/things"},
                 stub(fn c -> c end)
               )
    end

    test "refusal happens before any socket is opened" do
      assert {:error, {:invalid_request, :unvalidated_spec}} =
               Client.request(
                 %{method: :get, url: "https://api.acme.test/x"},
                 stub(fn _conn ->
                   flunk("the executor opened a socket for an unvalidated spec")
                 end)
               )
    end
  end

  describe "response shaping" do
    test "truncates an oversized binary body and flags it" do
      opts = stub(fn conn -> Plug.Conn.resp(conn, 200, String.duplicate("x", 500)) end)

      assert {:ok, %{body: body, truncated: true}} =
               Client.request(spec(), stub_with(opts, max_response_bytes: 100))

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
               Client.request(spec(), stub_with(opts, max_response_bytes: 50))

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
               Client.request(spec(), stub_with(opts, max_response_bytes: 1))
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

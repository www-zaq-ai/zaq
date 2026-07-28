defmodule Zaq.Channels.ReqTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.Req, as: Client

  # Every test that should reach the "network" installs a Req.Test plug, which
  # both stubs the transport and tells the destination check that no real
  # socket is opened. Guard tests use literal IPs, which need no DNS.
  defp stub(fun), do: [req_options: [plug: fun]]

  defp spec(overrides \\ %{}) do
    Map.merge(
      %{
        method: :get,
        url: "https://api.acme.test/v1/things",
        headers: %{},
        query: %{},
        body: nil,
        body_format: "json"
      },
      overrides
    )
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
                   method: :post,
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
                 spec(%{method: :post, body: %{"a" => "b"}, body_format: "form"}),
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
                 spec(%{method: :post, body: "<xml/>", body_format: "raw"}),
                 raw
               )
    end

    test "accepts a string-keyed spec with a string method" do
      opts =
        stub(fn conn ->
          assert conn.method == "PUT"
          Plug.Conn.resp(conn, 200, "ok")
        end)

      assert {:ok, %{status: 200}} =
               Client.request(
                 %{"method" => "PUT", "url" => "https://api.acme.test/v1/things"},
                 opts
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

    test "rejects an unknown method and a blank url" do
      assert {:error, {:invalid_method, "TELEPORT"}} =
               Client.request(spec(%{method: "TELEPORT"}), stub(fn c -> c end))

      assert {:error, {:invalid_url, ""}} =
               Client.request(spec(%{url: ""}), stub(fn c -> c end))
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

  describe "destination safety" do
    test "rejects loopback, private, link-local, and CGNAT addresses" do
      for host <- [
            "127.0.0.1",
            "10.0.0.5",
            "192.168.1.1",
            "172.16.0.1",
            "169.254.169.254",
            "100.64.0.1",
            "[::1]"
          ] do
        assert {:error, {:private_host_not_allowed, _}} =
                 Client.request(spec(%{url: "http://#{host}/x"}), stub(fn c -> c end)),
               "expected #{host} to be refused"
      end
    end

    test "rejects an IPv4-mapped IPv6 loopback" do
      assert {:error, {:private_host_not_allowed, _}} =
               Client.request(spec(%{url: "http://[::ffff:127.0.0.1]/x"}), stub(fn c -> c end))
    end

    test "allows a public literal address" do
      opts = stub(fn conn -> Plug.Conn.resp(conn, 200, "ok") end)

      assert {:ok, %{status: 200}} = Client.request(spec(%{url: "http://93.184.216.34/x"}), opts)
    end

    test "allows a private address when explicitly permitted" do
      opts = stub(fn conn -> Plug.Conn.resp(conn, 200, "ok") end)

      assert {:ok, %{status: 200}} =
               Client.request(
                 spec(%{url: "http://127.0.0.1/x"}),
                 stub_with(opts, allow_private_hosts: true)
               )
    end

    test "rejects a non-http scheme" do
      assert {:error, {:unsupported_scheme, _}} =
               Client.request(spec(%{url: "file:///etc/passwd"}), stub(fn c -> c end))

      assert {:error, {:unsupported_scheme, _}} =
               Client.request(spec(%{url: "ftp://acme.test/x"}), stub(fn c -> c end))
    end

    test "rejects a url with no host" do
      assert {:error, {:invalid_url, _}} =
               Client.request(spec(%{url: "/v1/things"}), stub(fn c -> c end))
    end

    test "enforces an allowlist by exact host and by domain suffix" do
      opts = stub(fn conn -> Plug.Conn.resp(conn, 200, "ok") end)

      allowed = stub_with(opts, allowed_hosts: ["api.acme.test", ".internal.acme.test"])

      assert {:ok, _} = Client.request(spec(), allowed)

      assert {:ok, _} =
               Client.request(spec(%{url: "https://sub.internal.acme.test/x"}), allowed)

      assert {:error, {:host_not_allowed, "evil.test"}} =
               Client.request(spec(%{url: "https://evil.test/x"}), allowed)
    end

    test "an empty allowlist permits any public host" do
      opts = stub(fn conn -> Plug.Conn.resp(conn, 200, "ok") end)

      assert {:ok, _} = Client.request(spec(), stub_with(opts, allowed_hosts: []))
    end

    test "rejects a hostname that does not resolve, when not stubbed" do
      assert {:error, {:unresolvable_host, _}} =
               Client.request(spec(%{url: "https://nonexistent.invalid/x"}), [])
    end
  end

  describe "secret placeholders (resolution deferred)" do
    test "sends a placeholder through literally rather than resolving it" do
      opts =
        stub(fn conn ->
          assert Plug.Conn.get_req_header(conn, "authorization") ==
                   ["Bearer {{secret:acme_key}}"]

          Plug.Conn.resp(conn, 200, "ok")
        end)

      assert {:ok, %{status: 200}} =
               Client.request(
                 spec(%{headers: %{"authorization" => "Bearer {{secret:acme_key}}"}}),
                 opts
               )
    end
  end

  defp stub_with(opts, extra), do: Keyword.merge(opts, extra)
end

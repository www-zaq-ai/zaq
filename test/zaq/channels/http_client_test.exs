defmodule Zaq.Channels.HttpClientTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.HttpClient, as: Client
  alias Zaq.HttpRequest
  alias Zaq.HttpRequest.Prepared
  alias Zaq.System.OutboundHttpPolicy

  defmodule TestPlug do
    @moduledoc false
    def init(opts), do: opts
    def call(conn, opts), do: Keyword.fetch!(opts, :handler).(conn, Keyword.fetch!(opts, :parent))
  end

  defp policy(overrides \\ %{}) do
    struct!(
      OutboundHttpPolicy,
      Map.merge(
        %{
          enabled: true,
          allowed_methods: ~w(GET HEAD OPTIONS POST PUT PATCH DELETE),
          block_loopback: false,
          max_response_bytes: 100_000
        },
        overrides
      )
    )
  end

  defp with_server(handler, fun) do
    {:ok, pid} = Bandit.start_link(plug: {TestPlug, handler: handler, parent: self()}, port: 0)
    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)

    try do
      fun.("http://127.0.0.1:#{port}")
    after
      ref = Process.monitor(pid)
      GenServer.stop(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        1_000 -> :ok
      end
    end
  end

  defp spec(base_url, overrides \\ %{}, policy \\ policy()) do
    {:ok, request} =
      %{method: "GET", url: base_url <> "/v1/things"}
      |> Map.merge(overrides)
      |> HttpRequest.build()

    %Prepared{
      method: request.method |> Atom.to_string() |> String.upcase(),
      url: request.url,
      uri: URI.parse(request.url),
      headers: request.headers,
      query: request.query,
      body: request.body,
      body_format: request.body_format,
      timeout_ms: request.timeout_ms,
      doc_reference: request.doc_reference,
      policy: policy
    }
  end

  describe "performing the request" do
    test "sends method, path, headers, and json body, and returns the response" do
      with_server(
        fn conn, parent ->
          send(
            parent,
            {:request, conn.method, conn.request_path, Plug.Conn.get_req_header(conn, "x-trace")}
          )

          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(parent, {:body, Jason.decode!(body)})

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(201, ~s({"id":"thing_1"}))
        end,
        fn base_url ->
          assert {:ok, response} =
                   Client.request(
                     spec(base_url, %{
                       method: "POST",
                       headers: %{"x-trace" => "abc"},
                       body: %{"sku" => "A1"}
                     })
                   )

          assert_received {:request, "POST", "/v1/things", ["abc"]}
          assert_received {:body, %{"sku" => "A1"}}
          assert response.status == 201
          assert response.success
          assert response.body == %{"id" => "thing_1"}
        end
      )
    end

    test "sends query parameters and credentials from the prepared contract" do
      with_server(
        fn conn, parent ->
          conn = Plug.Conn.fetch_query_params(conn)

          send(
            parent,
            {:request, conn.query_params, Plug.Conn.get_req_header(conn, "authorization")}
          )

          Plug.Conn.resp(conn, 200, "ok")
        end,
        fn base_url ->
          prepared = %{
            spec(base_url, %{query: %{"page" => "2"}})
            | credential: {:header, "authorization", "Bearer secret"}
          }

          assert {:ok, %{status: 200}} = Client.request(prepared)
          assert_received {:request, %{"page" => "2"}, ["Bearer secret"]}
        end
      )
    end

    test "sends form and raw bodies" do
      with_server(
        fn conn, parent ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(parent, {:body, body})
          Plug.Conn.resp(conn, 200, "ok")
        end,
        fn base_url ->
          assert {:ok, _} =
                   Client.request(
                     spec(base_url, %{method: "POST", body: %{"a" => "b"}, body_format: "form"})
                   )

          assert_received {:body, "a=b"}

          assert {:ok, _} =
                   Client.request(
                     spec(base_url, %{method: "POST", body: "<xml/>", body_format: "raw"})
                   )

          assert_received {:body, "<xml/>"}
        end
      )
    end

    test "reports statuses, transport failures, and does not follow redirects" do
      with_server(
        fn conn, _parent ->
          conn
          |> Plug.Conn.put_resp_header("location", "http://127.0.0.1/internal")
          |> Plug.Conn.resp(302, "")
        end,
        fn base_url ->
          assert {:ok, %{status: 302, success: false}} = Client.request(spec(base_url))
        end
      )

      prepared = %Prepared{
        method: "GET",
        url: "http://127.0.0.1:1/unreachable",
        uri: URI.parse("http://127.0.0.1:1/unreachable"),
        headers: %{},
        query: %{},
        body_format: "json",
        timeout_ms: 100,
        doc_reference: "",
        policy: policy()
      }

      assert {:error, {:transport_error, _}} = Client.request(prepared)
    end
  end

  describe "refusing unprepared specs" do
    test "source has no generic config, DB, or Req option injection seam" do
      source = File.read!("lib/zaq/channels/http_client.ex")

      refute source =~ "Zaq.Config"
      refute source =~ "Application."
      refute source =~ "Zaq.Repo"
      refute source =~ "alias Zaq.System\n"
      refute source =~ "Zaq.Engine.Connect"
      refute source =~ "req_options"
      refute source =~ "adapter:"
      refute source =~ "plug:"
    end

    test "rejects bare maps and non-prepared request structs" do
      assert {:error, :unprepared_request, _} =
               Client.request(%{method: :get, url: "https://api.acme.test/v1/things"})

      assert {:error, :unprepared_request, _} =
               Client.request(%HttpRequest{method: :get, url: "http://127.0.0.1/internal"})
    end

    test "a prepared request cannot bypass destination policy" do
      prepared = %Prepared{
        method: "GET",
        url: "http://127.0.0.1/internal",
        uri: URI.parse("http://127.0.0.1/internal"),
        headers: %{},
        query: %{},
        body_format: "json",
        timeout_ms: 1_000,
        doc_reference: "",
        policy: %OutboundHttpPolicy{enabled: true, allowed_methods: ~w(GET)}
      }

      assert {:error, :blocked_loopback, _} = Client.request(prepared)
    end
  end

  describe "response shaping" do
    test "truncates oversized bodies and keeps small ones" do
      with_server(
        fn conn, _parent -> Plug.Conn.resp(conn, 200, String.duplicate("x", 500)) end,
        fn base_url ->
          assert {:ok, %{body: body, truncated: true}} =
                   Client.request(spec(base_url, %{}, policy(%{max_response_bytes: 100})))

          assert byte_size(body) == 100
        end
      )

      with_server(fn conn, _parent -> Plug.Conn.resp(conn, 200, "small") end, fn base_url ->
        assert {:ok, %{body: "small", truncated: false}} = Client.request(spec(base_url))
      end)
    end

    test "lowercases response headers and drops sensitive ones" do
      with_server(
        fn conn, _parent ->
          conn
          |> Plug.Conn.put_resp_header("X-Rate-Limit", "10")
          |> Plug.Conn.put_resp_header("set-cookie", "session=secret")
          |> Plug.Conn.resp(200, "ok")
        end,
        fn base_url ->
          assert {:ok, %{headers: headers}} = Client.request(spec(base_url))
          assert headers["x-rate-limit"] == "10"
          refute Map.has_key?(headers, "set-cookie")
        end
      )
    end
  end
end

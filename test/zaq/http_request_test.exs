defmodule Zaq.HttpRequestTest do
  use ExUnit.Case, async: true

  alias Zaq.HttpRequest

  defp build(params, opts \\ []), do: HttpRequest.build(params, opts)

  defp base(overrides \\ %{}),
    do: Map.merge(%{method: "GET", url: "https://api.acme.test/x"}, overrides)

  describe "build/2 — shape" do
    test "builds a POST with a json body and downcased headers" do
      assert {:ok, request} =
               build(%{
                 method: "POST",
                 url: "https://api.acme.test/v1/orders",
                 headers: %{"Content-Type" => "application/json", "X-Trace" => "abc"},
                 body: %{"sku" => "A1", "qty" => 2}
               })

      assert request.method == :post
      assert request.url == "https://api.acme.test/v1/orders"
      assert request.headers == %{"content-type" => "application/json", "x-trace" => "abc"}
      assert request.body == %{"sku" => "A1", "qty" => 2}
      assert request.body_format == "json"
      assert request.timeout_ms == 30_000
    end

    test "stringifies query values" do
      assert {:ok, request} =
               build(base(%{method: "PUT", query: %{"dry_run" => true, "version" => 3}}))

      assert request.query == %{"dry_run" => "true", "version" => "3"}
    end

    test "records the documentation reference it was built from" do
      assert {:ok, request} =
               build(base(%{doc_reference: "https://docs.acme.test/orders#create"}))

      assert request.doc_reference == "https://docs.acme.test/orders#create"
    end

    test "honours an explicit timeout" do
      assert {:ok, %{timeout_ms: 5_000}} = build(base(%{timeout_ms: 5_000}))
    end
  end

  describe "build/2 — url" do
    test "rejects a non-http scheme, a relative url, and a malformed url" do
      for url <- ["file:///etc/passwd", "/v1/orders", "ftp://acme.test/x", "https://"] do
        assert {:error, message} = build(base(%{url: url}))
        assert is_binary(message)
      end
    end

    test "rejects a url carrying its own query string" do
      assert {:error, message} = build(base(%{url: "https://api.acme.test/x?a=1"}))
      assert message =~ "must not carry a query string"
    end

    test "rejects a url that is not a string" do
      assert {:error, message} = build(base(%{url: nil}))
      assert message =~ "must be a string"
    end
  end

  describe "build/2 — destination allowlist" do
    test "permits any host when no allowlist is configured" do
      assert {:ok, _} = build(base(), allowed_hosts: [])
      assert {:ok, _} = build(base(), allowed_hosts: nil)
    end

    test "matches by exact host and by domain suffix" do
      allowed = [allowed_hosts: ["api.acme.test", ".internal.acme.test"]]

      assert {:ok, _} = build(base(), allowed)
      assert {:ok, _} = build(base(%{url: "https://sub.internal.acme.test/x"}), allowed)
    end

    test "rejects a host outside the allowlist" do
      assert {:error, message} =
               build(base(%{url: "https://evil.test/x"}), allowed_hosts: ["api.acme.test"])

      assert message =~ "evil.test"
      assert message =~ "allowlist"
    end

    test "matching is case-insensitive on both sides" do
      assert {:ok, _} =
               build(base(%{url: "https://API.Acme.Test/x"}), allowed_hosts: ["api.acme.TEST"])
    end

    test "a suffix rule does not match the bare domain" do
      assert {:error, _} =
               build(base(%{url: "https://acme.test/x"}), allowed_hosts: [".acme.test"])
    end
  end

  describe "build/2 — method" do
    test "rejects an unknown method" do
      assert {:error, message} = build(base(%{method: "TELEPORT"}))
      assert message =~ "method must be one of"
    end

    test "rejects a missing method" do
      assert {:error, _} = build(%{url: "https://api.acme.test/x"})
    end
  end

  describe "build/2 — headers and query" do
    test "rejects a blank header name and a non-string header value" do
      assert {:error, blank} = build(base(%{headers: %{"" => "v"}}))
      assert blank =~ "must not be blank"

      assert {:error, non_string} = build(base(%{headers: %{"x-count" => 3}}))
      assert non_string =~ "must be a string"
    end

    test "rejects a non-scalar query value" do
      assert {:error, message} = build(base(%{query: %{"filter" => %{"nested" => true}}}))
      assert message =~ "must be a string, number, or boolean"
    end

    test "rejects headers, query, or auth that are not maps" do
      for field <- [:headers, :query] do
        assert {:error, message} = build(base(%{field => "nope"}))
        assert message =~ "#{field} must be a map"
      end
    end
  end

  describe "build/2 — body" do
    test "rejects a body on GET and DELETE but allows an empty one" do
      for method <- ["GET", "DELETE"] do
        assert {:error, message} = build(base(%{method: method, body: %{"a" => 1}}))
        assert message =~ "must not carry a body"

        assert {:ok, %{body: nil}} = build(base(%{method: method, body: %{}}))
      end
    end

    test "rejects a body whose shape does not match body_format" do
      assert {:error, json_msg} =
               build(base(%{method: "POST", body: "not a map", body_format: "json"}))

      assert json_msg =~ "needs a map or list body"

      assert {:error, raw_msg} =
               build(base(%{method: "POST", body: %{"a" => 1}, body_format: "raw"}))

      assert raw_msg =~ "needs a string body"

      assert {:error, form_msg} =
               build(base(%{method: "POST", body: "a=b", body_format: "form"}))

      assert form_msg =~ "needs a map body"
    end

    test "rejects an unknown body_format" do
      assert {:error, message} = build(base(%{method: "POST", body_format: "xml"}))
      assert message =~ ~s|body_format must be "json", "form", or "raw"|
    end
  end

  describe "build/2 — credentials are refused" do
    test "rejects a literal authorization header without echoing the token" do
      assert {:error, message} =
               build(base(%{headers: %{"Authorization" => "Bearer sk_live_secret"}}))

      assert message =~ "do not pass authorization as a header"
      assert message =~ "conversation history"
      refute message =~ "sk_live_secret"
    end

    test "rejects a proxy-authorization header too" do
      assert {:error, message} =
               build(base(%{headers: %{"proxy-authorization" => "Basic abc"}}))

      assert message =~ "proxy-authorization"
    end

    test "an auth parameter is not a thing the spec understands" do
      # Passing `auth` is silently ignored rather than rendering a credential:
      # there is no auth mechanism to route it to.
      assert {:ok, request} = build(base(%{auth: %{"type" => "bearer", "ref" => "acme_key"}}))

      assert request.headers == %{}
    end
  end

  describe "to_req_options/1" do
    test "carries method, url, headers, params, and the body under its format key" do
      assert {:ok, request} =
               build(%{
                 method: "POST",
                 url: "https://api.acme.test/x",
                 headers: %{"x-trace" => "abc"},
                 query: %{"page" => 2},
                 body: %{"a" => "b"}
               })

      opts = HttpRequest.to_req_options(request)

      assert opts[:method] == :post
      assert opts[:url] == "https://api.acme.test/x"
      assert opts[:headers] == %{"x-trace" => "abc"}
      assert opts[:params] == %{"page" => "2"}
      assert opts[:json] == %{"a" => "b"}
    end

    test "omits params and body when there are none" do
      assert {:ok, request} = build(base())
      opts = HttpRequest.to_req_options(request)

      refute Keyword.has_key?(opts, :params)
      refute Keyword.has_key?(opts, :json)
    end

    test "form and raw bodies map to the matching req option" do
      assert {:ok, form} =
               build(base(%{method: "POST", body: %{"a" => "b"}, body_format: "form"}))

      assert HttpRequest.to_req_options(form)[:form] == %{"a" => "b"}

      assert {:ok, raw} = build(base(%{method: "POST", body: "<xml/>", body_format: "raw"}))
      assert HttpRequest.to_req_options(raw)[:body] == "<xml/>"
    end
  end
end

defmodule Zaq.HttpRequestConfigTest do
  # Not async: the allowlist is read from application env, which is global.
  use ExUnit.Case, async: false

  alias Zaq.HttpRequest

  setup do
    previous = Application.get_env(:zaq, HttpRequest)
    on_exit(fn -> restore(previous) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:zaq, HttpRequest)
  defp restore(previous), do: Application.put_env(:zaq, HttpRequest, previous)

  test "the allowlist is read from application config" do
    Application.put_env(:zaq, HttpRequest, allowed_hosts: ["api.acme.test"])

    assert {:ok, _} = HttpRequest.build(%{method: "GET", url: "https://api.acme.test/x"})

    assert {:error, message} =
             HttpRequest.build(%{method: "GET", url: "https://evil.test/x"})

    assert message =~ "allowlist"
  end

  test "per-call opts override the configured allowlist" do
    Application.put_env(:zaq, HttpRequest, allowed_hosts: ["api.acme.test"])

    assert {:ok, _} =
             HttpRequest.build(%{method: "GET", url: "https://other.test/x"},
               allowed_hosts: ["other.test"]
             )
  end
end

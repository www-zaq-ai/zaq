defmodule Zaq.HttpRequestTest do
  use ExUnit.Case, async: true

  alias Zaq.HttpRequest

  defp build(params, opts \\ []), do: HttpRequest.build(params, opts)

  defp base(overrides \\ %{}),
    do: Map.merge(%{method: "GET", url: "https://api.acme.test/x"}, overrides)

  describe "build/2" do
    test "builds a POST with a json body and downcased headers" do
      assert {:ok, request} =
               build(%{
                 method: "POST",
                 url: "https://api.acme.test/v1/orders",
                 headers: %{"Content-Type" => "application/json", "X-Trace" => "abc"},
                 query: %{"dry_run" => true, "version" => 3},
                 body: %{"sku" => "A1", "qty" => 2},
                 credential_id: "12"
               })

      assert request.method == :post
      assert request.url == "https://api.acme.test/v1/orders"
      assert request.headers == %{"content-type" => "application/json", "x-trace" => "abc"}
      assert request.query == %{"dry_run" => "true", "version" => "3"}
      assert request.body == %{"sku" => "A1", "qty" => 2}
      assert request.body_format == "json"
      assert request.timeout_ms == 30_000
      assert request.credential_id == 12
    end

    test "supports every method supported by the shared validator" do
      for method <- ~w(GET HEAD OPTIONS POST PUT PATCH DELETE QUERY) do
        params =
          if method in ~w(GET HEAD OPTIONS DELETE),
            do: base(%{method: method}),
            else: base(%{method: method, body: %{}})

        assert {:ok, request} = build(params)
        assert request.method == method |> String.downcase() |> String.to_existing_atom()
      end
    end

    test "records the documentation reference it was built from" do
      assert {:ok, request} =
               build(base(%{doc_reference: "https://docs.acme.test/orders#create"}))

      assert request.doc_reference == "https://docs.acme.test/orders#create"
    end

    test "honours an explicit timeout within the structural policy cap" do
      assert {:ok, %{timeout_ms: 5_000}} = build(base(%{timeout_ms: 5_000}))
      assert {:error, message} = build(base(%{timeout_ms: 120_001}))
      assert message =~ "timeout exceeds"
    end
  end

  describe "build/2 — validation" do
    test "rejects non-http, relative, malformed, query, fragment, and userinfo urls" do
      for url <- [
            "file:///etc/passwd",
            "/v1/orders",
            "ftp://acme.test/x",
            "https://",
            "https://api.acme.test/x?a=1",
            "https://api.acme.test/x#token",
            "https://user:pass@api.acme.test/x"
          ] do
        assert {:error, message} = build(base(%{url: url}))
        assert is_binary(message)
      end
    end

    test "rejects invalid methods, header/query shape, body shape, and body format" do
      assert {:error, method} = build(base(%{method: "TELEPORT"}))
      assert method =~ "method is not supported"

      assert {:error, header} = build(base(%{headers: %{"x-count" => 3}}))
      assert header =~ "header x-count must be a string"

      assert {:error, query} = build(base(%{query: %{"filter" => %{"nested" => true}}}))
      assert query =~ "query values must be strings, numbers, or booleans"

      assert {:error, body} = build(base(%{method: "POST", body: "not a map"}))
      assert body =~ "body shape does not match body_format"

      assert {:error, format} = build(base(%{method: "POST", body_format: "xml"}))
      assert format =~ "body_format must be json, form, or raw"
    end

    test "rejects literal credential headers without echoing the token" do
      assert {:error, message} =
               build(base(%{headers: %{"Authorization" => "Bearer sk_live_secret"}}))

      assert message =~ "literal authorization headers are not allowed"
      refute message =~ "sk_live_secret"

      assert {:error, _message} =
               build(base(%{headers: %{"proxy-authorization" => "Basic abc"}}))
    end

    test "ignores unknown auth params rather than rendering a credential" do
      assert {:ok, request} = build(base(%{auth: %{"type" => "bearer", "ref" => "acme_key"}}))
      assert request.headers == %{}
    end
  end
end

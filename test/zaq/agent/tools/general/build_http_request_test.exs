defmodule Zaq.Agent.Tools.General.BuildHttpRequestTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.General.BuildHttpRequest
  alias Zaq.Engine.Workflows.Action

  defp build(params) do
    with {:ok, validated} <- BuildHttpRequest.validate_params(params) do
      BuildHttpRequest.run(validated, %{})
    end
  end

  test "satisfies the workflow action contract" do
    assert :ok = Action.validate(BuildHttpRequest)
  end

  test "is registered in the tool registry" do
    assert Zaq.Agent.Tools.Registry.valid_tool_key?("general.build_http_request")

    assert {:ok, [BuildHttpRequest]} =
             Zaq.Agent.Tools.Registry.resolve_modules(["general.build_http_request"])
  end

  describe "building a request" do
    test "builds a POST with a json body and downcased headers" do
      assert {:ok, %{request: request, req_options: opts, secret_refs: []}} =
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

      assert opts[:method] == :post
      assert opts[:url] == "https://api.acme.test/v1/orders"
      assert opts[:json] == %{"sku" => "A1", "qty" => 2}
      assert opts[:receive_timeout] == 30_000
      refute Keyword.has_key?(opts, :params)
    end

    test "builds a PUT and carries the query map into req params" do
      assert {:ok, %{request: request, req_options: opts}} =
               build(%{
                 method: "PUT",
                 url: "https://api.acme.test/v1/orders/1",
                 query: %{"dry_run" => true, "version" => 3},
                 body: %{"qty" => 5}
               })

      assert request.method == :put
      assert request.query == %{"dry_run" => "true", "version" => "3"}
      assert opts[:params] == %{"dry_run" => "true", "version" => "3"}
    end

    test "form and raw bodies map to the matching req option" do
      assert {:ok, %{req_options: form_opts}} =
               build(%{
                 method: "POST",
                 url: "https://api.acme.test/f",
                 body: %{"a" => "b"},
                 body_format: "form"
               })

      assert form_opts[:form] == %{"a" => "b"}

      assert {:ok, %{req_options: raw_opts}} =
               build(%{
                 method: "POST",
                 url: "https://api.acme.test/f",
                 body: "<xml/>",
                 body_format: "raw"
               })

      assert raw_opts[:body] == "<xml/>"
    end

    test "honours an explicit timeout" do
      assert {:ok, %{req_options: opts}} =
               build(%{method: "GET", url: "https://api.acme.test/x", timeout_ms: 5_000})

      assert opts[:receive_timeout] == 5_000
    end

    test "records the documentation reference it was built from" do
      assert {:ok, %{request: request}} =
               build(%{
                 method: "GET",
                 url: "https://api.acme.test/x",
                 doc_reference: "https://docs.acme.test/orders#create"
               })

      assert request.doc_reference == "https://docs.acme.test/orders#create"
    end
  end

  describe "auth references" do
    test "bearer renders a placeholder and reports the ref" do
      assert {:ok, %{request: request, secret_refs: ["stripe_key"]}} =
               build(%{
                 method: "POST",
                 url: "https://api.acme.test/charge",
                 auth: %{"type" => "bearer", "ref" => "stripe_key"},
                 body: %{"amount" => 1}
               })

      assert request.headers["authorization"] == "Bearer {{secret:stripe_key}}"
    end

    test "basic renders a placeholder the resolver base64-encodes" do
      assert {:ok, %{request: request, secret_refs: ["legacy_creds"]}} =
               build(%{
                 method: "GET",
                 url: "https://api.acme.test/x",
                 auth: %{"type" => "basic", "ref" => "legacy_creds"}
               })

      assert request.headers["authorization"] == "Basic {{secret:legacy_creds}}"
    end

    test "api_key defaults to x-api-key and accepts a custom header and prefix" do
      assert {:ok, %{request: default}} =
               build(%{
                 method: "GET",
                 url: "https://api.acme.test/x",
                 auth: %{"type" => "api_key", "ref" => "acme_key"}
               })

      assert default.headers["x-api-key"] == "{{secret:acme_key}}"

      assert {:ok, %{request: custom}} =
               build(%{
                 method: "GET",
                 url: "https://api.acme.test/x",
                 auth: %{
                   "type" => "api_key",
                   "ref" => "acme_key",
                   "header" => "X-Acme-Token",
                   "prefix" => "Token"
                 }
               })

      assert custom.headers["x-acme-token"] == "Token {{secret:acme_key}}"
    end

    test "type none and an absent auth add no header" do
      assert {:ok, %{request: none, secret_refs: []}} =
               build(%{
                 method: "GET",
                 url: "https://api.acme.test/x",
                 auth: %{"type" => "none"}
               })

      assert none.headers == %{}

      assert {:ok, %{request: absent}} =
               build(%{method: "GET", url: "https://api.acme.test/x"})

      assert absent.headers == %{}
    end

    test "accepts atom-keyed auth from a workflow step" do
      assert {:ok, %{request: request}} =
               build(%{
                 method: "GET",
                 url: "https://api.acme.test/x",
                 auth: %{type: "bearer", ref: "acme_key"}
               })

      assert request.headers["authorization"] == "Bearer {{secret:acme_key}}"
    end

    test "collects placeholders written by hand into headers, query, and body" do
      assert {:ok, %{secret_refs: refs}} =
               build(%{
                 method: "POST",
                 url: "https://api.acme.test/x",
                 headers: %{"x-tenant" => "{{secret:tenant_id}}"},
                 query: %{"key" => "{{secret:acme_key}}"},
                 body: %{"nested" => %{"pass" => "{{secret:db_pass}}"}},
                 auth: %{"type" => "bearer", "ref" => "acme_key"}
               })

      assert refs == ["acme_key", "db_pass", "tenant_id"]
    end

    test "rejects a literal authorization header and points at auth" do
      assert {:error, message} =
               build(%{
                 method: "GET",
                 url: "https://api.acme.test/x",
                 headers: %{"Authorization" => "Bearer sk_live_secret"}
               })

      assert message =~ "do not pass authorization as a header"
      assert message =~ "`auth`"
      refute message =~ "sk_live_secret"
    end

    test "rejects a proxy-authorization header too" do
      assert {:error, message} =
               build(%{
                 method: "GET",
                 url: "https://api.acme.test/x",
                 headers: %{"proxy-authorization" => "Basic abc"}
               })

      assert message =~ "proxy-authorization"
    end

    test "rejects a ref that is already wrapped in a placeholder" do
      assert {:error, message} =
               build(%{
                 method: "GET",
                 url: "https://api.acme.test/x",
                 auth: %{"type" => "bearer", "ref" => "{{secret:acme_key}}"}
               })

      assert message =~ "do not wrap it"
    end

    test "rejects a ref that looks like a credential value" do
      assert {:error, message} =
               build(%{
                 method: "GET",
                 url: "https://api.acme.test/x",
                 auth: %{"type" => "bearer", "ref" => "sk live/secret+value=="}
               })

      assert message =~ "may only contain letters"
    end

    test "rejects a missing or blank ref" do
      for ref <- [nil, "", "   "] do
        auth =
          if is_nil(ref), do: %{"type" => "bearer"}, else: %{"type" => "bearer", "ref" => ref}

        assert {:error, message} =
                 build(%{method: "GET", url: "https://api.acme.test/x", auth: auth})

        assert message =~ "ref"
      end
    end

    test "rejects a missing or unsupported auth type" do
      assert {:error, message} =
               build(%{
                 method: "GET",
                 url: "https://api.acme.test/x",
                 auth: %{"ref" => "acme_key"}
               })

      assert message =~ ~s|auth must declare a "type"|

      assert {:error, message} =
               build(%{
                 method: "GET",
                 url: "https://api.acme.test/x",
                 auth: %{"type" => "oauth1", "ref" => "acme_key"}
               })

      assert message =~ "unsupported auth type"
    end
  end

  describe "validation" do
    test "rejects a non-http scheme, a relative url, and a malformed url" do
      for url <- ["file:///etc/passwd", "/v1/orders", "ftp://acme.test/x", "https://"] do
        assert {:error, message} = build(%{method: "GET", url: url})
        assert is_binary(message)
      end
    end

    test "rejects a url carrying its own query string" do
      assert {:error, message} =
               build(%{method: "GET", url: "https://api.acme.test/x?a=1"})

      assert message =~ "must not carry a query string"
    end

    test "rejects a body on GET and DELETE but allows an empty one" do
      for method <- ["GET", "DELETE"] do
        assert {:error, message} =
                 build(%{
                   method: method,
                   url: "https://api.acme.test/x",
                   body: %{"a" => 1}
                 })

        assert message =~ "must not carry a body"

        assert {:ok, %{request: %{body: nil}}} =
                 build(%{method: method, url: "https://api.acme.test/x", body: %{}})
      end
    end

    test "rejects a body whose shape does not match body_format" do
      assert {:error, json_msg} =
               build(%{
                 method: "POST",
                 url: "https://api.acme.test/x",
                 body: "not a map",
                 body_format: "json"
               })

      assert json_msg =~ "needs a map or list body"

      assert {:error, raw_msg} =
               build(%{
                 method: "POST",
                 url: "https://api.acme.test/x",
                 body: %{"a" => 1},
                 body_format: "raw"
               })

      assert raw_msg =~ "needs a string body"

      assert {:error, form_msg} =
               build(%{
                 method: "POST",
                 url: "https://api.acme.test/x",
                 body: "a=b",
                 body_format: "form"
               })

      assert form_msg =~ "needs a map body"
    end

    test "rejects a blank header name and a non-string header value" do
      assert {:error, blank} =
               build(%{method: "GET", url: "https://api.acme.test/x", headers: %{"" => "v"}})

      assert blank =~ "must not be blank"

      assert {:error, non_string} =
               build(%{
                 method: "GET",
                 url: "https://api.acme.test/x",
                 headers: %{"x-count" => 3}
               })

      assert non_string =~ "must be a string"
    end

    test "rejects a non-scalar query value" do
      assert {:error, message} =
               build(%{
                 method: "GET",
                 url: "https://api.acme.test/x",
                 query: %{"filter" => %{"nested" => true}}
               })

      assert message =~ "must be a string, number, or boolean"
    end

    test "rejects an unknown method, a missing method, and a missing url" do
      assert {:error, _} =
               BuildHttpRequest.validate_params(%{method: "TRACE", url: "https://a.t"})

      assert {:error, _} = BuildHttpRequest.validate_params(%{url: "https://a.t"})
      assert {:error, _} = BuildHttpRequest.validate_params(%{method: "GET"})
    end

    test "rejects an unknown body_format" do
      assert {:error, _} =
               BuildHttpRequest.validate_params(%{
                 method: "POST",
                 url: "https://api.acme.test/x",
                 body_format: "xml"
               })
    end
  end
end

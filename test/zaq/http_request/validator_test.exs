defmodule Zaq.HttpRequest.ValidatorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.HttpRequest.Validator
  alias Zaq.System.OutboundHttpPolicy

  defp policy(overrides \\ %{}) do
    struct!(OutboundHttpPolicy, Map.merge(%{enabled: true}, overrides))
  end

  defp valid_params(overrides \\ %{}) do
    Map.merge(%{method: "GET", url: "https://api.example.com/v1/items"}, overrides)
  end

  test "normalizes a structurally valid request" do
    assert {:ok, request} =
             Validator.validate(
               valid_params(%{
                 method: " post ",
                 headers: %{"X-Trace" => "abc"},
                 query: %{"page" => 2},
                 body: %{"name" => "A"},
                 timeout_ms: 5_000,
                 credential_id: "12"
               }),
               policy(%{allowed_methods: ~w(GET HEAD OPTIONS POST)})
             )

    assert request.method == "POST"
    assert request.url == "https://api.example.com/v1/items"
    assert request.headers == %{"x-trace" => "abc"}
    assert request.query == %{"page" => "2"}
    assert request.credential_id == 12
  end

  test "fails closed when policy disables outbound HTTP" do
    assert {:error, :disabled, _} = Validator.validate(valid_params(), %OutboundHttpPolicy{})
  end

  test "rejects a non-map request" do
    assert Validator.validate([], policy()) ==
             {:error, :invalid_request, "request must be a map"}
  end

  test "rejects a whitespace-only method" do
    assert Validator.validate(valid_params(%{method: "   "}), policy()) ==
             {:error, :invalid_method, "method is required"}
  end

  test "rejects malformed and non-string URLs" do
    assert Validator.validate(valid_params(%{url: "https://[invalid/path"}), policy()) ==
             {:error, :invalid_url, "url is not a valid URI"}

    assert Validator.validate(valid_params(%{url: 123}), policy()) ==
             {:error, :invalid_url, "url must be a string"}
  end

  test "enforces method and port policy" do
    assert {:error, :method_not_allowed, _} =
             Validator.validate(valid_params(%{method: "POST"}), policy())

    assert {:error, :port_not_allowed, _} =
             Validator.validate(
               valid_params(%{url: "https://api.example.com:8443/v1/items"}),
               policy(%{allowed_ports: [443]})
             )
  end

  test "rejects userinfo, query strings, fragments, and literal credential headers" do
    for url <- [
          "https://user:pass@api.example.com/v1/items",
          "https://api.example.com/v1/items?a=1",
          "https://api.example.com/v1/items#token"
        ] do
      assert {:error, :invalid_url, _} = Validator.validate(valid_params(%{url: url}), policy())
    end

    assert {:error, :credential_not_allowed, _} =
             Validator.validate(
               valid_params(%{headers: %{"Authorization" => "Bearer secret"}}),
               policy()
             )
  end

  test "enforces host blacklists before DNS validation" do
    assert {:error, :host_blacklisted, _} =
             Validator.validate(
               valid_params(%{url: "https://api.example.com/v1/items"}),
               policy(%{blacklisted_hosts: [".example.com"]})
             )
  end

  test "rejects an exactly blacklisted host" do
    assert Validator.validate(valid_params(), policy(%{blacklisted_hosts: ["api.example.com"]})) ==
             {:error, :host_blacklisted, "host api.example.com is blacklisted"}
  end

  test "rejects invalid header and query containers" do
    assert Validator.validate(valid_params(%{headers: %{" " => "value"}}), policy()) ==
             {:error, :invalid_headers, "header names must not be blank"}

    assert Validator.validate(valid_params(%{headers: []}), policy()) ==
             {:error, :invalid_headers, "headers must be a map"}

    assert Validator.validate(valid_params(%{query: []}), policy()) ==
             {:error, :invalid_query, "query must be a map"}
  end

  test "normalizes an empty GET body to nil" do
    assert {:ok, request} = Validator.validate(valid_params(%{body: ""}), policy())
    assert request.body == nil
  end

  test "validates body shape and timeout limits" do
    assert {:error, :invalid_body, _} =
             Validator.validate(valid_params(%{body: %{"x" => "y"}}), policy())

    assert {:error, :timeout_too_large, _} =
             Validator.validate(
               valid_params(%{timeout_ms: 10_000}),
               policy(%{max_timeout_ms: 1_000})
             )
  end

  test "rejects invalid timeout and credential references" do
    assert Validator.validate(valid_params(%{timeout_ms: 0}), policy()) ==
             {:error, :invalid_timeout, "timeout_ms must be a positive integer"}

    assert Validator.validate(valid_params(%{credential_id: "invalid"}), policy()) ==
             {:error, :invalid_credential_ref, "credential_id must be a positive integer"}

    assert Validator.validate(valid_params(%{credential_id: 0}), policy()) ==
             {:error, :invalid_credential_ref, "credential_id must be a positive integer"}
  end

  property "rejects representative non-map containers for headers and query" do
    check all(value <- one_of([list_of(integer(), max_length: 4), tuple({integer(), integer()})])) do
      assert {:error, :invalid_headers, _} =
               Validator.validate(valid_params(%{headers: value}), policy())

      assert {:error, :invalid_query, _} =
               Validator.validate(valid_params(%{query: value}), policy())
    end
  end
end

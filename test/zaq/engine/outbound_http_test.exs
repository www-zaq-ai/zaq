defmodule Zaq.Engine.OutboundHttpTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Connect.Credential
  alias Zaq.Engine.OutboundHttp
  alias Zaq.HttpRequest
  alias Zaq.System.{HttpCredentialProvider, HttpCredentialProviderRef, OutboundHttpPolicy}

  defmodule ConnectStub do
    def fetch_credential(id), do: Process.get({__MODULE__, :fetch_credential}).(id)
  end

  defmodule SystemStub do
    def get_outbound_http_policy,
      do: %OutboundHttpPolicy{enabled: true, allowed_methods: ~w(GET POST)}

    def get_http_credential_provider(id),
      do: Process.get({__MODULE__, :get_http_credential_provider}).(id)
  end

  test "returns a provider-unavailable error when the dynamic provider is missing" do
    Process.put({ConnectStub, :fetch_credential}, fn 42 -> {:ok, credential()} end)
    Process.put({SystemStub, :get_http_credential_provider}, fn 7 -> nil end)

    assert {:error, :credential_provider_not_found, "credential provider is unavailable"} =
             prepare(%{credential_id: 42})
  end

  test "returns the lookup error without consulting the system" do
    Process.put({ConnectStub, :fetch_credential}, fn 42 -> {:error, :storage_unavailable} end)

    assert {:error, :storage_unavailable, "credential is unavailable"} =
             prepare(%{credential_id: 42})

    refute Process.get({SystemStub, :get_http_credential_provider})
  end

  test "rejects static and malformed provider references before provider lookup" do
    for provider_ref <- ["github", "http:not-an-id"] do
      Process.put({ConnectStub, :fetch_credential}, fn 42 ->
        {:ok, credential(%{provider: provider_ref})}
      end)

      assert {:error, _reason, _message} = prepare(%{credential_id: 42})
      refute Process.get({SystemStub, :get_http_credential_provider})
    end
  end

  property "wildcard providers allow subdomains but not the apex or lookalikes" do
    check all(label <- StreamData.string(:alphanumeric, min_length: 1, max_length: 12)) do
      label = String.downcase(label)
      provider = provider(%{host_patterns: [".example.com"]})
      Process.put({ConnectStub, :fetch_credential}, fn 42 -> {:ok, credential()} end)
      Process.put({SystemStub, :get_http_credential_provider}, fn 7 -> provider end)

      assert {:ok, _prepared} =
               prepare(%{url: "https://#{label}.example.com/resource", credential_id: 42})

      assert {:error, :credential_host_not_allowed, _} =
               prepare(%{url: "https://example.com/resource", credential_id: 42})

      assert {:error, :credential_host_not_allowed, _} =
               prepare(%{url: "https://#{label}.example.com.evil/resource", credential_id: 42})
    end

    provider = provider(%{host_patterns: [".example.com"]})
    Process.put({ConnectStub, :fetch_credential}, fn 42 -> {:ok, credential()} end)
    Process.put({SystemStub, :get_http_credential_provider}, fn 7 -> provider end)

    assert {:ok, _prepared} =
             prepare(%{url: "https://SUB.Example.COM/resource", credential_id: 42})
  end

  test "rejects missing API keys without exposing secret material" do
    for api_key <- [nil, ""] do
      Process.put({ConnectStub, :fetch_credential}, fn 42 ->
        {:ok, credential(%{api_key: api_key})}
      end)

      Process.put({SystemStub, :get_http_credential_provider}, fn 7 -> provider() end)

      result = prepare(%{credential_id: 42})

      assert result == {:error, :credential_secret_missing, "credential secret is unavailable"}
      refute inspect(result) =~ "secret-token"
    end
  end

  test "renders supported credential placements into the prepared contract" do
    for {provider, expected} <- [
          {provider(), {:header, "authorization", "Bearer secret-token"}},
          {provider(%{auth_kind: "basic", placement: "authorization"}),
           {:auth, {:basic, "secret-token"}}},
          {provider(%{auth_kind: "api_key", placement: "header", parameter_name: "x-api-key"}),
           {:header, "x-api-key", "secret-token"}},
          {provider(%{auth_kind: "api_key", placement: "query", parameter_name: "api_key"}),
           {:query, "api_key", "secret-token"}}
        ] do
      Process.put({ConnectStub, :fetch_credential}, fn 42 -> {:ok, credential()} end)
      Process.put({SystemStub, :get_http_credential_provider}, fn 7 -> provider end)

      assert {:ok, prepared} = prepare(%{credential_id: 42})
      assert prepared.credential == expected
      refute inspect(prepared) =~ "secret-token"
    end
  end

  test "rejects unsupported authorization rendering without exposing secrets" do
    Process.put({ConnectStub, :fetch_credential}, fn 42 ->
      {:ok, credential(%{api_key: "custom-secret"})}
    end)

    Process.put({SystemStub, :get_http_credential_provider}, fn 7 ->
      provider(%{auth_kind: "custom", placement: "authorization"})
    end)

    result = prepare(%{credential_id: 42})

    assert result ==
             {:error, :credential_provider_invalid, "credential provider rendering is invalid"}

    refute inspect(result) =~ "custom-secret"
  end

  defp prepare(overrides) do
    {:ok, request} =
      %{method: "GET", url: "https://api.example.com/resource"}
      |> Map.merge(overrides)
      |> HttpRequest.build()

    OutboundHttp.prepare(request, connect_module: ConnectStub, system_module: SystemStub)
  end

  defp credential(overrides \\ %{}) do
    {:ok, provider_ref} = HttpCredentialProviderRef.format(7)

    struct!(
      %Credential{
        id: 42,
        name: "test credential",
        provider: provider_ref,
        auth_kind: "api_key",
        request_format: "raw",
        user_level: false,
        metadata: %{},
        api_key: "secret-token"
      },
      overrides
    )
  end

  defp provider(overrides \\ %{}) do
    struct!(
      %HttpCredentialProvider{
        id: 7,
        name: "test provider",
        auth_kind: "bearer",
        placement: "authorization",
        host_patterns: ["api.example.com"],
        enabled: true,
        metadata: %{}
      },
      overrides
    )
  end
end

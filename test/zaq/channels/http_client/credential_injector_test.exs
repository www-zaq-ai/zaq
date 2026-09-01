defmodule Zaq.Channels.HttpClient.CredentialInjectorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.HttpClient.CredentialInjector
  alias Zaq.Engine.Connect.Credential
  alias Zaq.System.HttpCredentialProvider
  alias Zaq.System.HttpCredentialProviderRef

  defmodule ConnectStub do
    def fetch_credential(id) do
      callback = Process.get({__MODULE__, :fetch_credential})
      callback.(id)
    end
  end

  defmodule SystemStub do
    def get_http_credential_provider(id) do
      callback = Process.get({__MODULE__, :get_http_credential_provider})
      callback.(id)
    end
  end

  test "returns a provider-unavailable error when the dynamic provider is missing" do
    credential = credential()

    Process.put({ConnectStub, :fetch_credential}, fn id ->
      send(self(), {:credential_lookup, id})
      {:ok, credential}
    end)

    Process.put({SystemStub, :get_http_credential_provider}, fn _id -> nil end)

    assert {:error, :credential_provider_not_found, "credential provider is unavailable"} =
             inject(credential)

    assert_receive {:credential_lookup, 42}
  end

  test "returns the lookup error without consulting the system" do
    Process.put({ConnectStub, :fetch_credential}, fn 42 -> {:error, :storage_unavailable} end)

    assert {:error, :storage_unavailable, "credential is unavailable"} = inject(credential())
    refute Process.get({SystemStub, :get_http_credential_provider})
  end

  test "rejects static providers without looking them up" do
    credential = credential(%{provider: "github"})
    Process.put({ConnectStub, :fetch_credential}, fn 42 -> {:ok, credential} end)

    assert {:error, :credential_provider_not_http, "credential is not an HTTP credential"} =
             inject(credential)

    refute Process.get({SystemStub, :get_http_credential_provider})
  end

  test "rejects malformed dynamic provider references without looking them up" do
    credential = credential(%{provider: "http:not-an-id"})
    Process.put({ConnectStub, :fetch_credential}, fn 42 -> {:ok, credential} end)

    assert {:error, :credential_provider_invalid, "credential provider reference is invalid"} =
             inject(credential)

    refute Process.get({SystemStub, :get_http_credential_provider})
  end

  property "wildcard providers allow subdomains but not the apex or lookalikes" do
    check all(label <- StreamData.string(:alphanumeric, min_length: 1, max_length: 12)) do
      label = String.downcase(label)
      provider = provider(%{host_patterns: [".example.com"]})
      Process.put({ConnectStub, :fetch_credential}, fn 42 -> {:ok, credential()} end)
      Process.put({SystemStub, :get_http_credential_provider}, fn 7 -> provider end)

      assert {:ok, _} =
               inject(credential(), provider, URI.parse("https://#{label}.example.com/resource"))

      assert {:error, :credential_host_not_allowed, _} =
               inject(credential(), provider, URI.parse("https://example.com/resource"))

      assert {:error, :credential_host_not_allowed, _} =
               inject(
                 credential(),
                 provider,
                 URI.parse("https://#{label}.example.com.evil/resource")
               )
    end

    provider = provider(%{host_patterns: [".example.com"]})

    assert {:ok, _} =
             inject(credential(), provider, URI.parse("https://SUB.Example.COM/resource"))
  end

  test "rejects missing API keys without exposing secret material" do
    for api_key <- [nil, ""] do
      credential = credential(%{api_key: api_key})
      provider = provider()
      Process.put({ConnectStub, :fetch_credential}, fn 42 -> {:ok, credential} end)
      Process.put({SystemStub, :get_http_credential_provider}, fn _id -> provider end)

      result = inject(credential)

      assert result == {:error, :credential_secret_missing, "credential secret is unavailable"}
      refute inspect(result) =~ "secret-token"
    end
  end

  test "renders basic authorization and replaces existing auth while preserving options" do
    credential = credential(%{api_key: "user:password"})
    provider = provider(%{auth_kind: "basic", placement: "authorization"})
    Process.put({ConnectStub, :fetch_credential}, fn 42 -> {:ok, credential} end)
    Process.put({SystemStub, :get_http_credential_provider}, fn 7 -> provider end)

    assert {:ok, options} =
             inject(credential, provider, URI.parse("https://api.example.com/resource"),
               auth: :old,
               headers: %{"x-existing" => "keep"},
               timeout: 5
             )

    assert options[:auth] == {:basic, "user:password"}
    assert options[:headers] == %{"x-existing" => "keep"}
    assert options[:timeout] == 5
  end

  test "rejects unsupported authorization rendering without exposing secrets" do
    credential = credential(%{api_key: "custom-secret"})
    provider = provider(%{auth_kind: "custom", placement: "authorization"})
    Process.put({ConnectStub, :fetch_credential}, fn 42 -> {:ok, credential} end)
    Process.put({SystemStub, :get_http_credential_provider}, fn 7 -> provider end)

    result = inject(credential, provider)

    assert result ==
             {:error, :credential_provider_invalid, "credential provider rendering is invalid"}

    refute inspect(result) =~ "custom-secret"
  end

  defp inject(
         credential,
         provider \\ valid_provider(),
         uri \\ URI.parse("https://api.example.com/resource"),
         req_options \\ []
       ) do
    CredentialInjector.inject(
      req_options,
      %{credential_id: credential.id, uri: uri, query: %{"existing" => "value"}},
      connect_module: ConnectStub,
      system_module: SystemStub
    )
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

  defp valid_provider, do: provider()

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

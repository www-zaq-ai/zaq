defmodule Zaq.Channels.HttpClientCredentialTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Connect
  alias Zaq.Engine.OutboundHttp
  alias Zaq.HttpRequest
  alias Zaq.System, as: ZaqSystem
  alias Zaq.System.{HttpCredentialProviderRef, OutboundHttpPolicy}

  defmodule SystemStub do
    alias Zaq.System.OutboundHttpPolicy

    def get_outbound_http_policy do
      %OutboundHttpPolicy{
        enabled: true,
        allowed_methods: ~w(GET POST),
        max_response_bytes: 100_000
      }
    end

    def get_http_credential_provider(id), do: Zaq.System.get_http_credential_provider(id)
  end

  def policy(overrides \\ %{}) do
    struct!(
      OutboundHttpPolicy,
      Map.merge(
        %{enabled: true, allowed_methods: ~w(GET POST), max_response_bytes: 100_000},
        overrides
      )
    )
  end

  defp prepared(attrs) do
    {:ok, request} =
      HttpRequest.build(Map.merge(%{method: "GET", url: "https://api.example.com/v1"}, attrs))

    {:ok, prepared} =
      OutboundHttp.prepare(request, system_module: SystemStub, connect_module: Connect)

    prepared
  end

  defp provider(attrs \\ %{}) do
    base = %{
      name: "Credential Provider #{System.unique_integer([:positive])}",
      auth_kind: "bearer",
      placement: "authorization",
      host_patterns: ["api.example.com"]
    }

    {:ok, provider} = ZaqSystem.create_http_credential_provider(Map.merge(base, attrs))
    provider
  end

  defp credential(provider, attrs \\ %{}) do
    {:ok, provider_ref} = HttpCredentialProviderRef.format(provider.id)

    base = %{
      name: "HTTP Credential #{System.unique_integer([:positive])}",
      provider: provider_ref,
      auth_kind: "api_key",
      request_format: "raw",
      user_level: false,
      metadata: %{},
      api_key: "secret-token"
    }

    {:ok, credential} = Connect.create_credential(Map.merge(base, attrs))
    credential
  end

  test "injects bearer credentials only at the channels transport boundary" do
    credential = credential(provider())

    prepared = prepared(%{credential_id: credential.id})

    assert prepared.credential == {:header, "authorization", "Bearer secret-token"}
    refute inspect(prepared) =~ "secret-token"
  end

  test "injects custom header and query credentials from provider placement" do
    header_credential =
      credential(
        provider(%{auth_kind: "api_key", placement: "header", parameter_name: "x-api-key"}),
        %{api_key: "header-secret"}
      )

    assert prepared(%{credential_id: header_credential.id}).credential ==
             {:header, "x-api-key", "header-secret"}

    query_credential =
      credential(
        provider(%{auth_kind: "api_key", placement: "query", parameter_name: "api_key"}),
        %{api_key: "query-secret"}
      )

    prepared = prepared(%{credential_id: query_credential.id})

    assert prepared.credential == {:query, "api_key", "query-secret"}
    refute inspect(prepared) =~ "query-secret"
  end

  test "rejects missing, disabled, and host-mismatched credential providers without exposing secrets" do
    disabled_credential = credential(provider(%{enabled: false}), %{api_key: "disabled-secret"})

    assert {:error, :credential_provider_disabled, message} =
             disabled_credential.id
             |> request_for_credential()
             |> OutboundHttp.prepare(system_module: SystemStub, connect_module: Connect)

    refute message =~ "disabled-secret"

    wrong_host_credential =
      credential(provider(%{host_patterns: ["api.other.test"]}), %{api_key: "wrong-host-secret"})

    assert {:error, :credential_host_not_allowed, message} =
             wrong_host_credential.id
             |> request_for_credential()
             |> OutboundHttp.prepare(system_module: SystemStub, connect_module: Connect)

    refute message =~ "wrong-host-secret"

    assert {:error, :credential_not_found, _} =
             999_999
             |> request_for_credential()
             |> OutboundHttp.prepare(system_module: SystemStub, connect_module: Connect)
  end

  defp request_for_credential(credential_id) do
    {:ok, request} =
      HttpRequest.build(%{
        method: "GET",
        url: "https://api.example.com/v1",
        credential_id: credential_id
      })

    request
  end
end

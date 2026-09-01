defmodule Zaq.Channels.HttpClientCredentialTest do
  use Zaq.DataCase, async: true

  alias Zaq.Channels.HttpClient
  alias Zaq.Engine.Connect
  alias Zaq.System, as: ZaqSystem
  alias Zaq.System.{HttpCredentialProviderRef, OutboundHttpPolicy}

  defmodule ConfigStub do
    def get(:zaq, HttpClient, [], opts), do: Keyword.fetch!(opts, :http_client_config)
  end

  defp test_opts(config), do: [config: ConfigStub, http_client_config: config]

  defp policy(overrides \\ %{}) do
    struct!(
      OutboundHttpPolicy,
      Map.merge(
        %{enabled: true, allowed_methods: ~w(GET POST), max_response_bytes: 100_000},
        overrides
      )
    )
  end

  defp resolver, do: fn _host, _family -> {:ok, [{93, 184, 216, 34}]} end

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

    opts =
      test_opts(
        policy: policy(),
        resolver: resolver(),
        req_options: [
          plug: fn conn ->
            assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer secret-token"]
            Plug.Conn.resp(conn, 200, "ok")
          end
        ]
      )

    assert {:ok, response} =
             HttpClient.request(
               %{method: "GET", url: "https://api.example.com/v1", credential_id: credential.id},
               opts
             )

    assert response.status == 200
    refute inspect(response) =~ "secret-token"
  end

  test "injects custom header and query credentials from provider placement" do
    header_credential =
      credential(
        provider(%{auth_kind: "api_key", placement: "header", parameter_name: "x-api-key"}),
        %{api_key: "header-secret"}
      )

    assert {:ok, _} =
             HttpClient.request(
               %{
                 method: "GET",
                 url: "https://api.example.com/v1",
                 credential_id: header_credential.id
               },
               test_opts(
                 policy: policy(),
                 resolver: resolver(),
                 req_options: [
                   plug: fn conn ->
                     assert Plug.Conn.get_req_header(conn, "x-api-key") == ["header-secret"]
                     Plug.Conn.resp(conn, 200, "ok")
                   end
                 ]
               )
             )

    query_credential =
      credential(
        provider(%{auth_kind: "api_key", placement: "query", parameter_name: "api_key"}),
        %{api_key: "query-secret"}
      )

    assert {:ok, response} =
             HttpClient.request(
               %{
                 method: "GET",
                 url: "https://api.example.com/v1",
                 credential_id: query_credential.id
               },
               test_opts(
                 policy: policy(),
                 resolver: resolver(),
                 req_options: [
                   plug: fn conn ->
                     assert conn.query_params["api_key"] == "query-secret"
                     Plug.Conn.resp(conn, 200, "ok")
                   end
                 ]
               )
             )

    assert response.url == "https://api.example.com/v1"
    refute inspect(response) =~ "query-secret"
  end

  test "rejects missing, disabled, and host-mismatched credential providers without exposing secrets" do
    disabled_credential = credential(provider(%{enabled: false}), %{api_key: "disabled-secret"})

    assert {:error, :credential_provider_disabled, message} =
             HttpClient.request(
               %{
                 method: "GET",
                 url: "https://api.example.com/v1",
                 credential_id: disabled_credential.id
               },
               test_opts(policy: policy(), resolver: resolver())
             )

    refute message =~ "disabled-secret"

    wrong_host_credential =
      credential(provider(%{host_patterns: ["api.other.test"]}), %{api_key: "wrong-host-secret"})

    assert {:error, :credential_host_not_allowed, message} =
             HttpClient.request(
               %{
                 method: "GET",
                 url: "https://api.example.com/v1",
                 credential_id: wrong_host_credential.id
               },
               test_opts(policy: policy(), resolver: resolver())
             )

    refute message =~ "wrong-host-secret"

    assert {:error, :credential_not_found, _} =
             HttpClient.request(
               %{method: "GET", url: "https://api.example.com/v1", credential_id: 999_999},
               test_opts(policy: policy(), resolver: resolver())
             )
  end
end

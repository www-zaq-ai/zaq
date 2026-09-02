defmodule Zaq.Engine.OutboundHttp do
  @moduledoc """
  Engine-owned preparation for outbound HTTP requests.

  This module is the only outbound HTTP path that loads database-backed policy,
  credentials, and provider rules. Channels receives only the prepared execution
  contract and never reads Engine-owned storage directly.
  """

  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.Credential
  alias Zaq.HttpRequest
  alias Zaq.HttpRequest.{Prepared, Validator}
  alias Zaq.System
  alias Zaq.System.{HttpCredentialProvider, HttpCredentialProviderRef}

  @spec prepare(HttpRequest.t(), keyword()) :: {:ok, Prepared.t()} | {:error, atom(), String.t()}
  def prepare(request, opts \\ [])

  def prepare(%HttpRequest{} = request, opts) when is_list(opts) do
    system = Keyword.get(opts, :system_module, System)
    connect = Keyword.get(opts, :connect_module, Connect)
    policy = system.get_outbound_http_policy()

    with {:ok, normalized} <- Validator.validate(HttpRequest.to_map(request), policy),
         {:ok, credential} <- prepare_credential(normalized, connect, system) do
      {:ok,
       %Prepared{
         method: normalized.method,
         url: normalized.url,
         uri: normalized.uri,
         headers: normalized.headers,
         query: normalized.query,
         body: normalized.body,
         body_format: normalized.body_format,
         timeout_ms: normalized.timeout_ms,
         doc_reference: normalized.doc_reference,
         policy: policy,
         credential: credential
       }}
    end
  end

  def prepare(_request, _opts), do: {:error, :invalid_request, "request must be an HTTP request"}

  defp prepare_credential(%{credential_id: nil}, _connect, _system), do: {:ok, nil}

  defp prepare_credential(%{credential_id: credential_id, uri: uri}, connect, system) do
    with {:ok, %Credential{} = credential} <- connect.fetch_credential(credential_id),
         {:ok, provider_id} <- dynamic_provider_id(credential.provider),
         %HttpCredentialProvider{} = provider <- system.get_http_credential_provider(provider_id),
         :ok <- ensure_provider_enabled(provider),
         :ok <- ensure_host_allowed(uri.host, provider),
         {:ok, secret} <- credential_secret(credential),
         {:ok, rendered} <- render(provider, secret) do
      {:ok, rendered}
    else
      nil -> {:error, :credential_provider_not_found, "credential provider is unavailable"}
      {:error, :not_found} -> {:error, :credential_not_found, "credential is unavailable"}
      {:error, reason, message} -> {:error, reason, message}
      {:error, reason} -> {:error, reason, "credential is unavailable"}
    end
  end

  defp dynamic_provider_id(provider_ref) do
    case HttpCredentialProviderRef.parse(provider_ref) do
      {:ok, {:http, id}} ->
        {:ok, id}

      {:ok, {:static, _}} ->
        {:error, :credential_provider_not_http, "credential is not an HTTP credential"}

      {:error, _} ->
        {:error, :credential_provider_invalid, "credential provider reference is invalid"}
    end
  end

  defp ensure_provider_enabled(%HttpCredentialProvider{enabled: true}), do: :ok

  defp ensure_provider_enabled(%HttpCredentialProvider{}),
    do: {:error, :credential_provider_disabled, "credential provider is disabled"}

  defp ensure_host_allowed(host, %HttpCredentialProvider{host_patterns: patterns}) do
    host = String.downcase(host)

    if Enum.any?(patterns, &host_matches?(host, &1)),
      do: :ok,
      else: {:error, :credential_host_not_allowed, "credential is not allowed for this host"}
  end

  defp host_matches?(host, "." <> suffix), do: String.ends_with?(host, "." <> suffix)
  defp host_matches?(host, allowed), do: host == allowed

  defp credential_secret(%Credential{auth_kind: "api_key", api_key: value})
       when is_binary(value) and value != "",
       do: {:ok, value}

  defp credential_secret(%Credential{}),
    do: {:error, :credential_secret_missing, "credential secret is unavailable"}

  defp render(%HttpCredentialProvider{placement: "authorization", auth_kind: "bearer"}, secret),
    do: {:ok, {:header, "authorization", "Bearer " <> secret}}

  defp render(%HttpCredentialProvider{placement: "authorization", auth_kind: "basic"}, secret),
    do: {:ok, {:auth, {:basic, secret}}}

  defp render(%HttpCredentialProvider{placement: "header", parameter_name: name}, secret),
    do: {:ok, {:header, name, secret}}

  defp render(%HttpCredentialProvider{placement: "query", parameter_name: name}, secret),
    do: {:ok, {:query, name, secret}}

  defp render(%HttpCredentialProvider{}, _secret),
    do: {:error, :credential_provider_invalid, "credential provider rendering is invalid"}
end

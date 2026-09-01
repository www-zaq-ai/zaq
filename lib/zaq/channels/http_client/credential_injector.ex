defmodule Zaq.Channels.HttpClient.CredentialInjector do
  @moduledoc """
  Resolves outbound HTTP Auth Credentials and injects them into Req options.

  The request crossing the agent/channels boundary carries only `credential_id`.
  This module resolves the credential and BO-managed HTTP provider on the
  channels side, then renders the secret immediately before transport.
  """

  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.Credential
  alias Zaq.System
  alias Zaq.System.{HttpCredentialProvider, HttpCredentialProviderRef}

  @type normalized_request :: %{required(:uri) => URI.t(), required(:query) => map()}

  @doc "Adds credential-backed auth options to `req_options` when requested."
  @spec inject(keyword(), normalized_request(), keyword()) ::
          {:ok, keyword()} | {:error, atom(), String.t()}
  def inject(req_options, %{credential_id: nil}, _opts), do: {:ok, req_options}

  def inject(req_options, %{credential_id: credential_id} = request, opts) do
    connect = Keyword.get(opts, :connect_module, Connect)
    system = Keyword.get(opts, :system_module, System)

    with {:ok, %Credential{} = credential} <- fetch_credential(connect, credential_id),
         {:ok, provider_id} <- dynamic_provider_id(credential.provider),
         %HttpCredentialProvider{} = provider <- system.get_http_credential_provider(provider_id),
         :ok <- ensure_provider_enabled(provider),
         :ok <- ensure_host_allowed(request.uri.host, provider),
         {:ok, secret} <- credential_secret(credential),
         {:ok, rendered} <- render(provider, secret) do
      {:ok, merge_rendered(req_options, request, rendered)}
    else
      nil -> {:error, :credential_provider_not_found, "credential provider is unavailable"}
      {:error, :not_found} -> {:error, :credential_not_found, "credential is unavailable"}
      {:error, reason, message} -> {:error, reason, message}
      {:error, reason} -> {:error, reason, "credential is unavailable"}
    end
  end

  defp fetch_credential(connect, id), do: connect.fetch_credential(id)

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

  defp merge_rendered(req_options, _request, {:header, name, value}) do
    Keyword.update(req_options, :headers, %{name => value}, &Map.put(&1, name, value))
  end

  defp merge_rendered(req_options, _request, {:auth, auth}),
    do: Keyword.put(req_options, :auth, auth)

  defp merge_rendered(req_options, request, {:query, name, value}) do
    params = Map.put(request.query, name, value)
    Keyword.put(req_options, :params, params)
  end
end

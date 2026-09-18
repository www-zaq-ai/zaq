defmodule Zaq.Engine.Connect.OAuth do
  @moduledoc """
  Shared provider OAuth2 preparation/exchange and legacy org/user grant finalization.

  Raw Person owner contexts and old Person-owned signed states reject before signing
  or exchanging codes. Opaque attempt states route only to `OAuthAttempts`, which owns
  trusted Person/admin authorization and canonical finalization. Provider HTTP behavior
  is shared with legacy OAuth; no second provider registry or application config exists.
  Secret-bearing provider dispatches suppress NodeRouter workflow broadcasts.
  Refresh receives freshly loaded plaintext from the claimed Connect boundary; token
  strings are literal provider material and must never be decrypted a second time.
  Canonical token HTTP always uses this module's existing generic transport. Missing
  token URLs are resolved as secret-free profile metadata through Channels; catalog
  fallback requires an explicit client secret. Configured token URLs retain generic
  public-client support. Dependency token helpers are legacy-only because they may
  substitute environment credentials or omit PKCE fields from the actual request.
  """

  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.Credential
  alias Zaq.Engine.Connect.Grant
  alias Zaq.Engine.Connect.OAuthAttempts
  alias Zaq.Engine.Connect.OAuthState
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.Utils.DateUtils
  alias Zaq.Utils.Map, as: MapUtils

  @codex_redirect_uri "http://localhost:1455/auth/callback"

  @doc "Internal provider preparation shared by trusted attempts; contains a plaintext verifier."
  @spec prepare_attempt(Credential.t()) :: map()
  def prepare_attempt(%Credential{} = credential) do
    %{redirect_uri: redirect_uri_for(credential.provider), pkce: pkce_params(credential, true)}
  end

  @doc "Authorizes a persisted attempt using the existing provider infrastructure."
  @spec authorize_attempt(Credential.t(), String.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def authorize_attempt(credential, state, binding, opts \\ []) do
    {:ok, params} = authorize_params(credential, state, binding.pkce)
    params = Map.put(params, "redirect_uri", binding.redirect_uri)

    dispatch_data_source_oauth_action(
      credential.provider,
      params,
      :data_source_oauth_authorize_url,
      Keyword.put(opts, :oauth_credentials, :explicit)
    )
  end

  @doc "Exchanges a claimed attempt using only server-bound configuration and redirect/PKCE."
  @spec exchange_attempt(Credential.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def exchange_attempt(credential, code, binding, opts \\ []) do
    params =
      callback_params(credential, %{"code" => code}, %{})
      |> Map.delete("state")
      |> Map.put("redirect_uri", binding.redirect_uri)
      |> maybe_put_param("code_verifier", binding.pkce_verifier)

    with {:ok, token_url} <- token_endpoint(credential, true, opts),
         {:ok, payload} <- generic_exchange_code(token_url, params, opts) do
      {:ok, maybe_put_chatgpt_account_metadata(params, payload)}
    end
  end

  @spec build_authorize_url(Credential.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def build_authorize_url(%Credential{}, %{owner_type: type}) when type in ["person", :person],
    do: {:error, :person_management_required}

  def build_authorize_url(%Credential{}, %{"owner_type" => type})
      when type in ["person", :person],
      do: {:error, :person_management_required}

  def build_authorize_url(%Credential{auth_kind: "oauth2"} = credential, context)
      when is_map(context) do
    pkce_params = pkce_params(credential)
    state = OAuthState.sign(build_state_payload(credential, context, pkce_params))

    case authorize_params(credential, state, pkce_params) do
      {:ok, authorize_params} ->
        dispatch_data_source_oauth_action(
          credential.provider,
          authorize_params,
          :data_source_oauth_authorize_url
        )
    end
  end

  def build_authorize_url(%Credential{}, _context), do: {:error, :unsupported_auth_kind}

  @spec finalize_callback(String.t(), map()) ::
          {:ok, Connect.Grant.t() | map()} | {:error, term()}
  def finalize_callback(provider, %{"state" => state} = params)
      when is_binary(provider) and is_binary(state) do
    case OAuthState.verify(state) do
      {:ok, %{"attempt_id" => _}} -> OAuthAttempts.finalize_callback(provider, params)
      verified -> finalize_legacy(provider, params, verified)
    end
  end

  def finalize_callback(_provider, _params), do: {:error, :invalid_callback_params}

  defp finalize_legacy(provider, %{"code" => code} = params, verified) when is_binary(code) do
    with {:ok, state_payload} <- verified,
         :ok <- validate_legacy_owner(state_payload),
         :ok <- validate_provider(provider, state_payload),
         {:ok, credential} <- Connect.fetch_credential(state_payload["credential_id"]),
         {:ok, token_payload} <-
           dispatch_data_source_oauth_action(
             provider,
             callback_params(credential, params, state_payload),
             :data_source_oauth_exchange_code
           ) do
      Connect.issue_grant(build_oauth_grant_attrs(credential, state_payload, token_payload))
    end
  end

  defp finalize_legacy(_, _, _), do: {:error, :invalid_callback_params}

  @spec refresh_token_payload(Credential.t(), Grant.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | :fallback
  def refresh_token_payload(%Credential{} = credential, %Grant{} = grant, opts \\ []) do
    metadata = credential.metadata || %{}

    case token_endpoint(credential, grant.resource_type == "connect_credential", opts) do
      {:ok, token_url} ->
        params = refresh_params(credential, grant, metadata)

        with {:ok, token_payload} <- generic_refresh_token(token_url, params, opts) do
          {:ok, maybe_put_chatgpt_account_metadata(params, token_payload)}
        end

      other ->
        other
    end
  end

  # Provider profiles are Channels-owned. Only their secret-free endpoint crosses
  # back; token HTTP reuses our generic transport so PKCE and explicit credentials
  # cannot be dropped or replaced by dependency environment defaults.
  defp token_endpoint(credential, canonical?, opts) do
    case MapUtils.read_any(credential.metadata || %{}, ["token_url", :token_url]) do
      url when is_binary(url) and url != "" -> {:ok, url}
      _ when canonical? -> canonical_token_endpoint(credential, opts)
      _ -> :fallback
    end
  end

  defp canonical_token_endpoint(credential, opts) do
    if is_binary(credential.client_secret) and credential.client_secret != "" do
      case dispatch_channels_oauth_action(
             credential.provider,
             %{},
             :data_source_oauth_token_endpoint,
             opts
           ) do
        {:ok, url} when is_binary(url) and url != "" -> {:ok, url}
        _ -> {:error, :unsupported_oauth_endpoint}
      end
    else
      # Catalog adapters cannot guarantee public-client semantics. A configured
      # token_url opts into the existing generic public-client path instead.
      {:error, :oauth_client_secret_required}
    end
  end

  @spec redirect_uri_for(String.t()) :: String.t()
  def redirect_uri_for(provider) do
    base =
      Zaq.System.get_global_base_url() || "http://localhost:4000"

    base <> "/channels/oauth2/#{provider}/redirect"
  end

  defp build_state_payload(%Credential{} = credential, context, pkce_params) do
    %{
      "credential_id" => credential.id,
      "provider" => credential.provider,
      "resource_type" => Map.get(context, :resource_type) || Map.get(context, "resource_type"),
      "resource_id" =>
        to_string(Map.get(context, :resource_id) || Map.get(context, "resource_id")),
      "owner_type" => Map.get(context, :owner_type) || Map.get(context, "owner_type") || "org",
      "owner_id" => Map.get(context, :owner_id) || Map.get(context, "owner_id"),
      "metadata" => Map.get(context, :metadata) || Map.get(context, "metadata") || %{},
      "oauth" => state_oauth_payload(pkce_params)
    }
  end

  defp authorize_params(%Credential{} = credential, state, pkce_params) do
    metadata = credential.metadata || %{}

    {:ok,
     (MapUtils.read_any(metadata, ["authorize_params", :authorize_params]) || %{})
     |> MapUtils.stringify_keys()
     |> Map.merge(%{
       "authorize_url" => MapUtils.read_any(metadata, ["authorize_url", :authorize_url]),
       "client_id" => oauth_client_id(credential),
       "redirect_uri" => oauth_redirect_uri(credential),
       "scope" => oauth_scope(credential),
       "state" => state,
       "response_type" => "code"
     })
     |> Map.merge(Map.drop(pkce_params, ["code_verifier"]))}
  end

  defp callback_params(%Credential{} = credential, params, state_payload) do
    metadata = credential.metadata || %{}

    %{
      "code" => Map.get(params, "code"),
      "state" => Map.get(params, "state"),
      "redirect_uri" => oauth_redirect_uri(credential),
      "client_id" => oauth_client_id(credential),
      "client_secret" => credential.client_secret,
      "auth_profile" => MapUtils.read_any(metadata, ["auth_profile", :auth_profile]),
      "token_url" => MapUtils.read_any(metadata, ["token_url", :token_url])
    }
    |> maybe_put_param("code_verifier", get_in(state_payload, ["oauth", "code_verifier"]))
  end

  defp refresh_params(%Credential{} = credential, %Grant{} = grant, metadata) do
    %{
      "refresh_token" => grant.refresh_token,
      "client_id" => oauth_client_id(credential),
      "client_secret" => credential.client_secret,
      "auth_profile" => MapUtils.read_any(metadata, ["auth_profile", :auth_profile]),
      "scope" => oauth_scope(credential)
    }
  end

  defp oauth_client_id(%Credential{} = credential) do
    MapUtils.read_any(credential.metadata || %{}, ["client_id", :client_id]) ||
      credential.client_id
  end

  defp oauth_redirect_uri(%Credential{} = credential) do
    metadata = credential.metadata || %{}

    if MapUtils.read_any(metadata, ["auth_profile", :auth_profile]) == "openai_chatgpt_codex" do
      @codex_redirect_uri
    else
      redirect_uri_for(credential.provider)
    end
  end

  defp oauth_scope(%Credential{} = credential) do
    metadata = credential.metadata || %{}

    scope =
      MapUtils.read_any(metadata, ["scope", :scope]) ||
        Enum.join(credential.scopes || [], " ")

    scope
  end

  defp pkce_params(%Credential{} = credential, required \\ false) do
    metadata = credential.metadata || %{}

    if required or pkce_enabled?(metadata) do
      verifier = pkce_verifier()

      %{
        "code_verifier" => verifier,
        "code_challenge" => pkce_challenge(verifier),
        "code_challenge_method" => "S256"
      }
    else
      %{}
    end
  end

  defp pkce_enabled?(metadata),
    do:
      MapUtils.read_any(metadata, ["pkce", :pkce]) == true or
        MapUtils.read_any(metadata, ["auth_profile", :auth_profile]) == "openai_chatgpt_codex"

  defp pkce_verifier do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp pkce_challenge(verifier) do
    :sha256
    |> :crypto.hash(verifier)
    |> Base.url_encode64(padding: false)
  end

  defp state_oauth_payload(%{"code_verifier" => code_verifier}),
    do: %{"code_verifier" => code_verifier}

  defp state_oauth_payload(_pkce_params), do: %{}

  defp maybe_put_param(params, _key, nil), do: params
  defp maybe_put_param(params, _key, ""), do: params
  defp maybe_put_param(params, key, value), do: Map.put(params, key, value)

  defp validate_legacy_owner(%{"owner_type" => type}) when type in ["person", :person],
    do: {:error, :person_management_required}

  defp validate_legacy_owner(_), do: :ok

  defp validate_provider(provider, %{"provider" => provider}), do: :ok
  defp validate_provider(_provider, _payload), do: {:error, :provider_mismatch}

  defp build_oauth_grant_attrs(%Credential{} = credential, state_payload, token_payload) do
    %{
      credential_id: credential.id,
      provider: credential.provider,
      auth_kind: "oauth2",
      resource_type: state_payload["resource_type"],
      resource_id: state_payload["resource_id"],
      owner_type: state_payload["owner_type"],
      owner_id: state_payload["owner_id"],
      request_format: credential.request_format,
      metadata: grant_metadata(state_payload, token_payload),
      expires_at: Map.get(token_payload, :expires_at) || Map.get(token_payload, "expires_at"),
      access_token:
        Map.get(token_payload, :access_token) || Map.get(token_payload, "access_token"),
      refresh_token:
        Map.get(token_payload, :refresh_token) || Map.get(token_payload, "refresh_token"),
      scopes: normalize_token_scopes(grant_scopes(token_payload))
    }
  end

  defp grant_metadata(state_payload, token_payload) do
    Map.merge(
      state_payload["metadata"] || %{},
      Map.get(token_payload, :metadata) || Map.get(token_payload, "metadata") || %{}
    )
  end

  defp grant_scopes(token_payload) do
    Map.get(token_payload, :scopes) ||
      Map.get(token_payload, "scopes") ||
      Map.get(token_payload, :scope) ||
      Map.get(token_payload, "scope")
  end

  defp normalize_token_scopes(scopes) when is_list(scopes), do: scopes

  defp normalize_token_scopes(scopes) when is_binary(scopes) do
    scopes
    |> String.split()
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_token_scopes(_), do: []

  defp dispatch_data_source_oauth_action(provider, params, action, opts \\ []) do
    case dispatch_generic_oauth_action(params, action, opts) do
      :fallback -> dispatch_channels_oauth_action(provider, params, action, opts)
      result -> result
    end
  end

  defp dispatch_generic_oauth_action(
         %{"authorize_url" => authorize_url} = params,
         :data_source_oauth_authorize_url,
         _opts
       )
       when is_binary(authorize_url) and authorize_url != "" do
    {:ok, generic_authorize_url(authorize_url, params)}
  end

  defp dispatch_generic_oauth_action(
         %{"token_url" => token_url} = params,
         :data_source_oauth_exchange_code,
         opts
       )
       when is_binary(token_url) and token_url != "" do
    with {:ok, token_payload} <- generic_exchange_code(token_url, params, opts) do
      {:ok, maybe_put_chatgpt_account_metadata(params, token_payload)}
    end
  end

  defp dispatch_generic_oauth_action(_params, _action, _opts), do: :fallback

  defp dispatch_channels_oauth_action(provider, params, action, opts) do
    event =
      Event.new(
        %{provider: provider, params: params},
        :channels,
        opts:
          [action: action, confidential: true] ++
            Keyword.take(opts, [:oauth_credentials, :data_source_bridge_module, :config])
      )

    case NodeRouter.dispatch(event).response do
      {:ok, _} = ok -> ok
      {:error, _} = error -> error
      other -> {:error, {:invalid_oauth_response, other}}
    end
  end

  defp generic_authorize_url(authorize_url, params) do
    query_params =
      params
      |> Map.drop(["authorize_url", "token_url", "client_secret", "code_verifier"])
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Map.new()

    uri = URI.parse(authorize_url)

    existing_query =
      uri.query
      |> Kernel.||("")
      |> URI.decode_query()

    %{uri | query: URI.encode_query(Map.merge(existing_query, query_params))}
    |> URI.to_string()
  end

  defp generic_exchange_code(token_url, params, opts) do
    body =
      params
      |> Map.take([
        "code",
        "redirect_uri",
        "client_id",
        "client_secret",
        "code_verifier",
        "grant_type"
      ])
      |> Map.put_new("grant_type", "authorization_code")
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Map.new()

    post_token(token_url, body, [], :oauth_exchange_failed, opts)
  end

  defp generic_refresh_token(token_url, params, opts) do
    body =
      params
      |> Map.take(["refresh_token", "client_id", "client_secret", "scope"])
      |> Map.put("grant_type", "refresh_token")
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Map.new()

    post_token(
      token_url,
      body,
      [receive_timeout: 15_000, connect_options: [timeout: 5_000]],
      :oauth_refresh_failed,
      opts
    )
  end

  defp post_token(token_url, body, request_opts, error_tag, opts) do
    request_opts =
      [url: token_url, form: body, retry: false, headers: [{"accept", "application/json"}]] ++
        request_opts

    case oauth_http_client(opts).post(request_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, normalize_generic_token_payload(body, opts)}

      {:ok, %{status: status, body: body}} ->
        {:error, {error_tag, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_chatgpt_account_metadata(
         %{"auth_profile" => "openai_chatgpt_codex"},
         token_payload
       ) do
    case chatgpt_account_id(token_payload) do
      account_id when is_binary(account_id) and account_id != "" ->
        metadata = Map.get(token_payload, :metadata) || %{}
        Map.put(token_payload, :metadata, Map.put(metadata, "chatgpt_account_id", account_id))

      _ ->
        token_payload
    end
  end

  defp maybe_put_chatgpt_account_metadata(_params, token_payload), do: token_payload

  defp normalize_generic_token_payload(body, opts) do
    %{
      id_token: generic_token_value(body, "id_token"),
      access_token: generic_token_value(body, "access_token"),
      refresh_token: generic_token_value(body, "refresh_token"),
      scopes:
        normalize_token_scopes(
          generic_token_value(body, "scope") || generic_token_value(body, "scopes")
        ),
      expires_at: generic_token_expires_at(body, opts)
    }
  end

  defp generic_token_value(body, key),
    do: Map.get(body, key) || Map.get(body, String.to_atom(key))

  defp generic_token_expires_at(body, opts) do
    case generic_token_value(body, "expires_in") do
      seconds when is_integer(seconds) ->
        DateTime.add(DateUtils.now(opts), seconds, :second)

      _ ->
        generic_token_value(body, "expires_at")
    end
  end

  defp chatgpt_account_id(token_payload) do
    token_payload
    |> chatgpt_account_tokens()
    |> Enum.find_value(&chatgpt_account_id_from_token/1)
  end

  defp chatgpt_account_tokens(token_payload) do
    [
      Map.get(token_payload, :id_token) || Map.get(token_payload, "id_token"),
      Map.get(token_payload, :access_token) || Map.get(token_payload, "access_token")
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp chatgpt_account_id_from_token(token) do
    with [_header, payload, _signature] <- String.split(token, "."),
         {:ok, decoded} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(decoded) do
      claims["chatgpt_account_id"] ||
        get_in(claims, ["https://api.openai.com/auth", "chatgpt_account_id"]) ||
        get_in(claims, ["organizations", Access.at(0), "id"])
    else
      _ -> nil
    end
  end

  defp oauth_http_client(opts),
    do: Zaq.Config.get(:zaq, :connect_oauth_http_client, Req, opts)
end

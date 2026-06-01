defmodule Zaq.Engine.Connect.OAuth do
  @moduledoc "OAuth2 authorize URL generation and callback finalization for Connect grants."

  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.Credential
  alias Zaq.Engine.Connect.OAuthState
  alias Zaq.Event
  alias Zaq.NodeRouter

  @spec build_authorize_url(Credential.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def build_authorize_url(%Credential{auth_kind: "oauth2"} = credential, context)
      when is_map(context) do
    state = OAuthState.sign(build_state_payload(credential, context))

    case authorize_params(credential, state) do
      {:ok, authorize_params} ->
        dispatch_data_source_oauth_action(
          credential.provider,
          authorize_params,
          :data_source_oauth_authorize_url
        )
    end
  end

  def build_authorize_url(%Credential{}, _context), do: {:error, :unsupported_auth_kind}

  @spec finalize_callback(String.t(), map()) :: {:ok, Connect.Grant.t()} | {:error, term()}
  def finalize_callback(provider, %{"state" => state, "code" => code} = params)
      when is_binary(provider) and is_binary(state) and is_binary(code) do
    with {:ok, state_payload} <- OAuthState.verify(state),
         :ok <- validate_provider(provider, state_payload),
         {:ok, credential} <- Connect.fetch_credential(state_payload["credential_id"]),
         {:ok, token_payload} <-
           dispatch_data_source_oauth_action(
             provider,
             callback_params(credential, params),
             :data_source_oauth_exchange_code
           ) do
      Connect.issue_grant(build_oauth_grant_attrs(credential, state_payload, token_payload))
    end
  end

  def finalize_callback(_provider, _params), do: {:error, :invalid_callback_params}

  @spec redirect_uri_for(String.t()) :: String.t()
  def redirect_uri_for(provider) do
    base =
      Zaq.System.get_global_base_url() || "http://localhost:4000"

    base <> "/channels/oauth2/#{provider}/redirect"
  end

  defp build_state_payload(%Credential{} = credential, context) do
    %{
      "credential_id" => credential.id,
      "provider" => credential.provider,
      "resource_type" => Map.get(context, :resource_type) || Map.get(context, "resource_type"),
      "resource_id" =>
        to_string(Map.get(context, :resource_id) || Map.get(context, "resource_id")),
      "owner_type" => Map.get(context, :owner_type) || Map.get(context, "owner_type") || "org",
      "owner_id" => Map.get(context, :owner_id) || Map.get(context, "owner_id"),
      "metadata" => Map.get(context, :metadata) || Map.get(context, "metadata") || %{}
    }
  end

  defp authorize_params(%Credential{} = credential, state) do
    {:ok,
     %{
       "client_id" => credential.client_id,
       "redirect_uri" => redirect_uri_for(credential.provider),
       "scope" => Enum.join(credential.scopes || [], " "),
       "state" => state,
       "response_type" => "code"
     }}
  end

  defp callback_params(%Credential{} = credential, params) do
    %{
      "code" => Map.get(params, "code"),
      "state" => Map.get(params, "state"),
      "redirect_uri" => redirect_uri_for(credential.provider),
      "client_id" => credential.client_id,
      "client_secret" => credential.client_secret
    }
  end

  defp validate_provider(provider, %{"provider" => provider}), do: :ok
  defp validate_provider(_provider, _payload), do: {:error, :provider_mismatch}

  defp build_oauth_grant_attrs(%Credential{} = credential, state_payload, token_payload) do
    scopes =
      Map.get(token_payload, :scopes) ||
        Map.get(token_payload, "scopes") ||
        Map.get(token_payload, :scope) ||
        Map.get(token_payload, "scope")

    %{
      credential_id: credential.id,
      provider: credential.provider,
      auth_kind: "oauth2",
      resource_type: state_payload["resource_type"],
      resource_id: state_payload["resource_id"],
      owner_type: state_payload["owner_type"],
      owner_id: state_payload["owner_id"],
      request_format: credential.request_format,
      metadata: state_payload["metadata"] || %{},
      expires_at: Map.get(token_payload, :expires_at) || Map.get(token_payload, "expires_at"),
      access_token:
        Map.get(token_payload, :access_token) || Map.get(token_payload, "access_token"),
      refresh_token:
        Map.get(token_payload, :refresh_token) || Map.get(token_payload, "refresh_token"),
      scopes: normalize_token_scopes(scopes)
    }
  end

  defp normalize_token_scopes(scopes) when is_list(scopes), do: scopes

  defp normalize_token_scopes(scopes) when is_binary(scopes) do
    scopes
    |> String.split()
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_token_scopes(_), do: []

  defp dispatch_data_source_oauth_action(provider, params, action) do
    event =
      Event.new(
        %{provider: provider, params: params},
        :channels,
        opts: [action: action]
      )

    case NodeRouter.dispatch(event).response do
      {:ok, _} = ok -> ok
      {:error, _} = error -> error
      other -> {:error, {:invalid_oauth_response, other}}
    end
  end
end

defmodule ZaqWeb.Live.BO.System.SystemConfig.AICredentialEvents do
  @moduledoc """
  Stateless orchestration helpers for AI credential event flows.
  """

  def with_provider_endpoint(params, previous_provider, provider_endpoint_fun)
      when is_map(params) and is_function(provider_endpoint_fun, 1) do
    if params["provider"] != previous_provider do
      Map.put(params, "endpoint", provider_endpoint_fun.(params["provider"]))
    else
      params
    end
  end

  def with_provider_endpoint(params, _previous_provider, _provider_endpoint_fun), do: params

  def normalize_params(params) when is_map(params) do
    params
    |> normalize_metadata()
    |> apply_auth_mode()
  end

  def normalize_params(params), do: params

  def save(:edit, id, params, get_credential_fun, update_credential_fun, _create_credential_fun)
      when is_function(get_credential_fun, 1) and is_function(update_credential_fun, 2) do
    id
    |> get_credential_fun.()
    |> update_credential_fun.(params)
  end

  def save(
        _action,
        _id,
        params,
        _get_credential_fun,
        _update_credential_fun,
        create_credential_fun
      )
      when is_function(create_credential_fun, 1) do
    create_credential_fun.(params)
  end

  def delete(id, get_credential_fun, delete_credential_fun)
      when is_function(get_credential_fun, 1) and is_function(delete_credential_fun, 1) do
    id
    |> get_credential_fun.()
    |> delete_credential_fun.()
  end

  def open_new_modal(socket, load_form_fun) when is_function(load_form_fun, 1) do
    socket
    |> Phoenix.Component.assign(:ai_credential_action, :new)
    |> Phoenix.Component.assign(:ai_credential_id, nil)
    |> Phoenix.Component.assign(:ai_credential_modal, true)
    |> load_form_fun.()
  end

  def open_edit_modal(socket, credential, change_credential_fun)
      when is_function(change_credential_fun, 2) do
    socket
    |> Phoenix.Component.assign(:ai_credential_action, :edit)
    |> Phoenix.Component.assign(:ai_credential_id, credential.id)
    |> Phoenix.Component.assign(:ai_credential_modal, true)
    |> Phoenix.Component.assign(
      :ai_credential_form,
      credential
      |> change_credential_fun.(%{})
      |> Phoenix.Component.to_form(as: :ai_credential)
    )
  end

  def close_modal(socket) do
    socket
    |> Phoenix.Component.assign(:ai_credential_modal, false)
    |> Phoenix.Component.assign(:ai_credential_delete_confirm_modal, false)
  end

  def open_delete_confirm(socket),
    do: Phoenix.Component.assign(socket, :ai_credential_delete_confirm_modal, true)

  def cancel_delete_confirm(socket),
    do: Phoenix.Component.assign(socket, :ai_credential_delete_confirm_modal, false)

  defp normalize_metadata(%{"metadata" => metadata} = params) when is_binary(metadata) do
    case String.trim(metadata) do
      "" -> Map.put(params, "metadata", %{})
      json -> Map.put(params, "metadata", decode_metadata(json))
    end
  end

  defp normalize_metadata(params), do: params

  defp decode_metadata(json) do
    case Jason.decode(json) do
      {:ok, metadata} when is_map(metadata) -> metadata
      _ -> json
    end
  end

  defp apply_auth_mode(%{"auth_mode" => auth_mode} = params) do
    metadata = Map.get(params, "metadata")

    if is_map(metadata) do
      auth_mode = auth_mode_for_provider(params, auth_mode)

      params
      |> maybe_drop_api_key_for_oauth_only_provider()
      |> apply_auth_mode_to_metadata(auth_mode, metadata)
    else
      Map.delete(params, "auth_mode")
    end
  end

  defp apply_auth_mode(params), do: params

  defp apply_auth_mode_to_metadata(params, auth_mode, metadata) do
    metadata =
      case auth_mode do
        "api_key" -> Map.drop(metadata, ["auth_kind", :auth_kind, "auth_profile", :auth_profile])
        "oauth2" -> oauth2_metadata(params, metadata)
        _ -> metadata
      end

    params
    |> Map.put("metadata", metadata)
    |> Map.delete("auth_mode")
  end

  defp auth_mode_for_provider(%{"provider" => "openai_codex"}, _auth_mode), do: "oauth2"
  defp auth_mode_for_provider(_params, auth_mode), do: auth_mode

  defp maybe_drop_api_key_for_oauth_only_provider(%{"provider" => "openai_codex"} = params),
    do: Map.delete(params, "api_key")

  defp maybe_drop_api_key_for_oauth_only_provider(params), do: params

  defp oauth2_metadata(params, metadata) do
    metadata = Map.put(metadata, "auth_kind", "oauth2")

    if params["provider"] == "openai_codex" do
      metadata
      |> Map.put_new("auth_profile", "openai_chatgpt_codex")
      |> Map.put_new("authorize_url", "https://auth.openai.com/oauth/authorize")
      |> Map.put_new("token_url", "https://auth.openai.com/oauth/token")
      |> Map.put_new("client_id", "app_EMoamEEZ73f0CkXaXp7hrann")
      |> Map.put_new("scope", "openid profile email offline_access")
      |> merge_codex_authorize_params()
    else
      metadata
    end
  end

  defp merge_codex_authorize_params(metadata) do
    authorize_params =
      metadata
      |> Map.get("authorize_params", %{})
      |> normalize_authorize_params()
      |> Map.put("id_token_add_organizations", "true")
      |> Map.put("codex_cli_simplified_flow", "true")
      |> Map.put_new("originator", "zaqos")

    Map.put(metadata, "authorize_params", authorize_params)
  end

  defp normalize_authorize_params(params) when is_map(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_authorize_params(_params), do: %{}
end

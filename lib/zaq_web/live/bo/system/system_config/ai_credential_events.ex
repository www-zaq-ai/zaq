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
end

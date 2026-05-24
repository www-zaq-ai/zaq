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
end

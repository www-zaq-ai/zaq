defmodule ZaqWeb.Live.BO.System.SystemConfig.EmbeddingEvents do
  @moduledoc """
  Helpers for Embedding config event branching.
  """

  def maybe_open_save_confirm(socket, params) do
    if socket.assigns.model_changed do
      {:confirm,
       socket
       |> Phoenix.Component.assign(:embedding_save_confirm_modal, true)
       |> Phoenix.Component.assign(:pending_embedding_params, params)}
    else
      :save
    end
  end

  def unlock(socket, credential_options_fun) when is_function(credential_options_fun, 0) do
    socket
    |> Phoenix.Component.assign(:embedding_locked, false)
    |> Phoenix.Component.assign(:embedding_unlock_modal, false)
    |> Phoenix.Component.assign(:embedding_credential_options, credential_options_fun.())
  end
end

defmodule ZaqWeb.Live.BO.System.SystemConfig.ConnectCredentialEvents do
  @moduledoc """
  Helpers for Connect credential modal/event assign flows.
  """

  def close_modal(socket) do
    socket
    |> Phoenix.Component.assign(:connect_credential_modal, false)
    |> Phoenix.Component.assign(:connect_credential_changeset, nil)
    |> Phoenix.Component.assign(:connect_credential_form, nil)
    |> Phoenix.Component.assign(:connect_credential_errors, [])
    |> Phoenix.Component.assign(:connect_default_scopes_text, "")
  end

  def apply_changeset(socket, changeset) do
    socket
    |> Phoenix.Component.assign(:connect_credential_changeset, changeset)
    |> Phoenix.Component.assign(
      :connect_credential_form,
      Phoenix.Component.to_form(changeset, as: :credential)
    )
  end

  def apply_changeset_with_errors(socket, changeset, format_errors_fun)
      when is_function(format_errors_fun, 1) do
    socket
    |> apply_changeset(changeset)
    |> Phoenix.Component.assign(:connect_credential_errors, format_errors_fun.(changeset))
  end
end

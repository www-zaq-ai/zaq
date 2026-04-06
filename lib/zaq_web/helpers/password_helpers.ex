defmodule ZaqWeb.Helpers.PasswordHelpers do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias Zaq.Accounts.PasswordPolicy

  @doc "Assigns password feedback assigns to the socket based on current form params."
  def assign_password_feedback(socket, %{
        "password" => password,
        "password_confirmation" => confirmation
      }) do
    socket
    |> assign(:password_requirements, PasswordPolicy.requirements_with_status(password))
    |> assign(:password_requirements_met?, PasswordPolicy.valid_password?(password))
    |> assign(:password_confirmation_touched?, confirmation != "")
    |> assign(:passwords_match?, confirmation != "" and password == confirmation)
  end
end

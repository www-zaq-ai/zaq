defmodule ZaqWeb.Live.BO.System.ForgotPasswordLive do
  use ZaqWeb, :live_view

  alias Zaq.Accounts
  alias Zaq.Engine.Notifications.PasswordResetEmail

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:form, to_form(%{"email" => ""}))
     |> assign(:submitted, false)
     |> assign(:error, nil)}
  end

  def handle_event("validate", %{"email" => email}, socket) do
    {:noreply,
     socket
     |> assign(:form, to_form(%{"email" => email}))
     |> assign(:error, nil)}
  end

  def handle_event("send_reset", %{"email" => email}, socket) do
    trimmed = String.trim(email)

    case Accounts.get_user_by_email(trimmed) do
      %Accounts.User{} = user ->
        token = Accounts.generate_password_reset_token(user)
        PasswordResetEmail.deliver(user, token)
        {:noreply, assign(socket, :submitted, true)}

      nil ->
        {:noreply,
         socket
         |> assign(:form, to_form(%{"email" => email}))
         |> assign(:error, "No account found with that email address.")}
    end
  end
end

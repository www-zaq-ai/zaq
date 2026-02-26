defmodule ZaqWeb.Live.BO.LoginLive do
  use ZaqWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:form, to_form(%{"email" => "", "password" => "", "remember" => false}))
     |> assign(:error_message, nil)}
  end

  def handle_event("login", %{"email" => email, "password" => password} = params, socket) do
    # TODO: Replace with actual authentication logic
    socket =
      case authenticate(email, password) do
        {:ok, _user} ->
          push_navigate(socket, to: ~p"/bo/dashboard")

        {:error, reason} ->
          assign(socket, :error_message, reason)
      end

    {:noreply, socket}
  end

  def handle_event("validate", params, socket) do
    {:noreply, assign(socket, :form, to_form(params))}
  end

  # TODO: Replace with real auth
  defp authenticate(_email, _password) do
    {:error, "Invalid email or password"}
  end
end

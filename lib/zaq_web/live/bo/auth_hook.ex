defmodule ZaqWeb.Live.BO.AuthHook do
  @moduledoc """
  `on_mount` hook that authenticates LiveView connections for the BO section.

  Halts and redirects to the login page when no session is present, and to
  the password-change page when `must_change_password` is set on the user.
  """
  use ZaqWeb, :verified_routes

  import Phoenix.LiveView
  import Phoenix.Component

  alias Zaq.Accounts

  def on_mount(:default, _params, session, socket) do
    case session["user_id"] do
      nil ->
        {:halt, push_navigate(socket, to: ~p"/bo/login")}

      user_id ->
        user = Accounts.get_user!(user_id)

        if user.must_change_password and socket.view != ZaqWeb.Live.BO.System.ChangePasswordLive do
          {:halt, push_navigate(socket, to: ~p"/bo/change-password")}
        else
          {:cont, setup_license_hook(socket, user)}
        end
    end
  end

  defp setup_license_hook(socket, user) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Zaq.PubSub, "license:updated")
    end

    socket
    |> assign(:current_user, user)
    |> assign(:features_version, 0)
    |> attach_hook(:license_updated, :handle_info, &handle_license_updated/2)
  end

  defp handle_license_updated(:license_updated, socket) do
    {:cont, assign(socket, :features_version, socket.assigns.features_version + 1)}
  end

  defp handle_license_updated(_msg, socket) do
    {:cont, socket}
  end
end

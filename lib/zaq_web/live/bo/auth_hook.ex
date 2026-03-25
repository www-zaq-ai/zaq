defmodule ZaqWeb.Live.BO.AuthHook do
  @moduledoc """
  This module defines an on_mount hook for Phoenix LiveView that handles authentication and authorization for the back office (BO) section of the application. It checks if a user is logged in by looking for a user ID in the session, retrieves the corresponding user from the database, and assigns it to the socket. If no user ID is found, it redirects to the login page. Additionally, if the user has the `must_change_password` flag set to true, it redirects them to the change password page before allowing access to any other routes.
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

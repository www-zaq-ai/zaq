# lib/zaq_web/live/bo/auth_hook.ex

defmodule ZaqWeb.Live.BO.AuthHook do
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

        if user.must_change_password and socket.view != ZaqWeb.Live.BO.ChangePasswordLive do
          {:halt, push_navigate(socket, to: ~p"/bo/change-password")}
        else
          {:cont, assign(socket, :current_user, user)}
        end
    end
  end
end

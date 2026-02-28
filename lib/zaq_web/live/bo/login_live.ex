# lib/zaq_web/live/bo/login_live.ex

defmodule ZaqWeb.Live.BO.LoginLive do
  use ZaqWeb, :live_view

  alias Zaq.Accounts

  def mount(_params, session, socket) do
    case session["user_id"] do
      nil ->
        {:ok,
         socket
         |> assign(:form, to_form(%{"username" => "", "password" => ""}))}

      user_id ->
        user = Accounts.get_user!(user_id)

        redirect_path =
          if user.must_change_password, do: ~p"/bo/change-password", else: ~p"/bo/dashboard"

        {:ok, push_navigate(socket, to: redirect_path)}
    end
  end

  def handle_event("validate", params, socket) do
    {:noreply, assign(socket, :form, to_form(params))}
  end
end

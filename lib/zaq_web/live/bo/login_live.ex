# lib/zaq_web/live/bo/login_live.ex

defmodule ZaqWeb.Live.BO.LoginLive do
  use ZaqWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:form, to_form(%{"username" => "", "password" => ""}))
    }
  end

  def handle_event("validate", params, socket) do
    {:noreply, assign(socket, :form, to_form(params))}
  end
end

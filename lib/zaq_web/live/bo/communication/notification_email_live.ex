defmodule ZaqWeb.Live.BO.Communication.NotificationEmailLive do
  use ZaqWeb, :live_view
  on_mount {ZaqWeb.Live.BO.Communication.ServiceGate, [:channels]}

  alias Zaq.System

  @connection_types [
    %{
      id: "smtp",
      label: "SMTP",
      color: "#16a34a",
      desc:
        "Configure outbound email delivery using any SMTP relay. Supports STARTTLS, SSL/TLS, and custom authentication."
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    available = socket.assigns.service_available

    {:ok,
     socket
     |> assign(:page_title, "Email Notifications")
     |> assign(:current_path, "/bo/channels/notifications/email")
     |> assign(:cards, @connection_types)
     |> assign(:smtp_active, available && System.get_email_config().enabled)}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}
end

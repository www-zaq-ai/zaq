defmodule ZaqWeb.Live.BO.Communication.NotificationEmailLive do
  use ZaqWeb, :live_view
  on_mount {ZaqWeb.Live.BO.Communication.ServiceGate, [:channels]}

  alias Zaq.Channels.ChannelConfig

  @connection_types [
    %{
      id: "imap",
      label: "Receiving / IMAP",
      color: "#0284c7",
      desc:
        "Configure inbound email reception from selected mailboxes. ZAQ listens for unread messages and relays them to the pipeline."
    },
    %{
      id: "smtp",
      label: "Sending / SMTP",
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
     |> assign(:page_title, "Email Channel")
     |> assign(:current_path, "/bo/channels/retrieval/email")
     |> assign(:cards, @connection_types)
     |> assign(:smtp_active, available && ChannelConfig.get_by_provider("email:smtp") != nil)
     |> assign(:imap_active, available && ChannelConfig.get_by_provider("email:imap") != nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}
end

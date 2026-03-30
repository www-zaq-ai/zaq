# lib/zaq_web/live/bo/communication/channels_index_live.ex

defmodule ZaqWeb.Live.BO.Communication.ChannelsIndexLive do
  use ZaqWeb, :live_view
  on_mount {ZaqWeb.Live.BO.Communication.ServiceGate, [:channels]}

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Repo
  alias Zaq.System

  import Ecto.Query

  @retrieval_providers ~w(slack teams mattermost discord telegram webhook)
  @ingestion_providers ~w(zaq_local google_drive sharepoint)

  # ---------------------------------------------------------------------------
  # Provider card definitions — used by the template to render grids
  # ---------------------------------------------------------------------------

  @retrieval_cards [
    %{
      id: "slack",
      label: "Slack",
      color: "#4A154B",
      desc:
        "Connect workspaces, post messages, and trigger workflows from Slack channels and DMs."
    },
    %{
      id: "teams",
      label: "Microsoft Teams",
      color: "#464EB8",
      desc: "Send alerts and notifications directly into Teams channels via incoming webhooks."
    },
    %{
      id: "mattermost",
      label: "Mattermost",
      color: "#0058CC",
      desc:
        "Self-hosted messaging with full control. Integrate bots, post to channels, and receive events."
    },
    %{
      id: "discord",
      label: "Discord",
      color: "#5865F2",
      desc:
        "Post to Discord servers via webhooks. Great for communities, dev teams, and alert routing."
    },
    %{
      id: "telegram",
      label: "Telegram",
      color: "#26A5E4",
      desc:
        "Send and receive messages via Telegram Bot API. Ideal for ops alerts and lightweight bots."
    },
    %{
      id: "webhook",
      label: "Webhook",
      color: "#666666",
      desc: "POST events to any HTTP endpoint. Use for custom integrations, Zapier, Make, or n8n."
    }
  ]

  @notification_cards [
    %{
      id: "email",
      label: "Email",
      color: "#16a34a",
      desc:
        "Send email notifications to users for password resets, invitations, and system alerts."
    }
  ]

  @ingestion_cards [
    %{
      id: "zaq_local",
      label: "ZAQ Local",
      color: "#03b6d4",
      desc: "Upload and manage documents directly in ZAQ. The built-in knowledge base."
    },
    %{
      id: "google_drive",
      label: "Google Drive",
      color: "#4285F4",
      desc: "Sync documents from Google Drive folders. Supports Docs, Sheets, PDFs, and more."
    },
    %{
      id: "sharepoint",
      label: "SharePoint",
      color: "#036C70",
      desc: "Connect to SharePoint document libraries. Ingest files from sites and team drives."
    }
  ]

  # Provider IDs shown as mini-logos inside category cards on the index page
  @retrieval_preview ~w(slack teams mattermost discord telegram)
  @ingestion_preview ~w(zaq_local google_drive sharepoint)
  @notification_preview ~w(email)

  @impl true
  def mount(_params, _session, socket) do
    available = socket.assigns.service_available

    {:ok,
     socket
     |> assign(:retrieval_preview, @retrieval_preview)
     |> assign(:ingestion_preview, @ingestion_preview)
     |> assign(:notification_preview, @notification_preview)
     |> assign(:stats, if(available, do: compute_stats(), else: %{}))}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    kind = socket.assigns.live_action

    {page_title, current_path, cards} =
      case kind do
        :retrieval ->
          {"Communication Channels", "/bo/channels/retrieval", @retrieval_cards}

        :ingestion ->
          {"Ingestion Channels", "/bo/channels/ingestion", @ingestion_cards}

        :notification ->
          {"Notification Channels", "/bo/channels/notifications", @notification_cards}

        _index ->
          {"Channels", "/bo/channels", []}
      end

    {:noreply,
     socket
     |> assign(:page_title, page_title)
     |> assign(:current_path, current_path)
     |> assign(:kind, kind)
     |> assign(:cards, cards)}
  end

  # --- Helpers used by template ---

  def stat_for(stats, provider) do
    Map.get(stats, String.to_existing_atom(provider), 0)
  end

  def retrieval_total(stats) do
    Enum.reduce(@retrieval_providers, 0, fn p, acc ->
      acc + Map.get(stats, String.to_existing_atom(p), 0)
    end)
  end

  def ingestion_total(stats) do
    Enum.reduce(@ingestion_providers, 0, fn p, acc ->
      acc + Map.get(stats, String.to_existing_atom(p), 0)
    end)
  end

  def notification_total(stats), do: Map.get(stats, :email, 0)

  def provider_path(_kind, "zaq_local"), do: "/bo/ingestion"
  def provider_path(:retrieval, id), do: "/bo/channels/retrieval/#{id}"
  def provider_path(:ingestion, id), do: "/bo/channels/ingestion/#{id}"
  def provider_path(:notification, id), do: "/bo/channels/notifications/#{id}"

  # --- Private ---

  defp compute_stats do
    all_providers = @retrieval_providers ++ @ingestion_providers

    counts =
      ChannelConfig
      |> where([c], c.enabled == true)
      |> group_by([c], c.provider)
      |> select([c], {c.provider, count(c.id)})
      |> Repo.all()
      |> Map.new()

    base =
      Enum.reduce(all_providers, %{}, fn provider, acc ->
        Map.put(acc, String.to_atom(provider), Map.get(counts, provider, 0))
      end)

    email_active = if System.get_email_config().enabled, do: 1, else: 0
    Map.put(base, :email, email_active)
  end
end

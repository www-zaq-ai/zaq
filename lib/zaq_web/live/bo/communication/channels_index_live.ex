# lib/zaq_web/live/bo/communication/channels_index_live.ex

defmodule ZaqWeb.Live.BO.Communication.ChannelsIndexLive do
  use ZaqWeb, :live_view
  on_mount {ZaqWeb.Live.BO.Communication.ServiceGate, [:channels]}

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.Repo
  alias ZaqWeb.Live.BO.Communication.IngressStatusUI

  import Ecto.Query

  @retrieval_providers ~w(slack teams mattermost discord telegram webhook email)
  @data_source_providers ~w(zaq_local google_drive sharepoint)
  @notification_providers ~w(email:smtp)

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
    },
    %{
      id: "email",
      label: "Email",
      color: "#16a34a",
      desc:
        "Configure inbound IMAP reception and outbound SMTP sending from a single email channel entry."
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

  @data_source_cards [
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
  @data_source_preview ~w(zaq_local google_drive sharepoint)

  @impl true
  def mount(_params, _session, socket) do
    available = socket.assigns.service_available
    configured_providers = if(available, do: configured_retrieval_providers(), else: MapSet.new())

    {:ok,
     socket
     |> assign(:retrieval_preview, @retrieval_preview)
     |> assign(:data_source_preview, @data_source_preview)
     |> assign(:stats, if(available, do: compute_stats(), else: %{}))
     |> assign(:configured_ingress_providers, configured_providers)
     |> assign(:ingress_statuses, %{})
     |> assign(:ingress_status_loading, ingress_status_loading(configured_providers))
     |> assign(:ingress_status_modal, nil)
     |> schedule_ingress_status_refresh(configured_providers)}
  end

  @impl true
  def handle_async(:ingress_statuses, result, socket) do
    {:noreply, IngressStatusUI.apply_async_result(socket, result)}
  end

  @impl true
  def handle_event("open_ingress_status", %{"provider" => provider}, socket) do
    status = Map.get(socket.assigns.ingress_statuses || %{}, provider)
    {:noreply, assign(socket, :ingress_status_modal, %{provider: provider, status: status})}
  end

  def handle_event("close_ingress_status", _params, socket) do
    {:noreply, assign(socket, :ingress_status_modal, nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    kind = socket.assigns.live_action

    {page_title, current_path, cards} =
      case kind do
        :retrieval ->
          {"Communication Channels", "/bo/channels/retrieval", @retrieval_cards}

        :data_source ->
          {"Data Sources", "/bo/channels/data_source", @data_source_cards}

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
    case provider do
      "email" ->
        Map.get(stats, :"email:imap", 0) + Map.get(stats, :"email:smtp", 0)

      _ ->
        Map.get(stats, String.to_existing_atom(provider), 0)
    end
  rescue
    ArgumentError ->
      0
  end

  def retrieval_total(stats) do
    Enum.reduce(@retrieval_providers, 0, fn p, acc ->
      acc + Map.get(stats, String.to_existing_atom(p), 0)
    end)
  end

  def data_source_total(stats) do
    Enum.reduce(@data_source_providers, 0, fn p, acc ->
      acc + Map.get(stats, String.to_existing_atom(p), 0)
    end)
  end

  def notification_total(stats) do
    Enum.reduce(@notification_providers, 0, fn p, acc ->
      acc + Map.get(stats, String.to_existing_atom(p), 0)
    end)
  end

  def provider_path(_kind, "zaq_local"), do: "/bo/ingestion"
  def provider_path(:retrieval, "email"), do: "/bo/channels/retrieval/email"
  def provider_path(:retrieval, id), do: "/bo/channels/retrieval/#{id}"
  def provider_path(:data_source, id), do: "/bo/channels/data_source/#{id}"
  def provider_path(:notification, id), do: "/bo/channels/notifications/#{id}"

  # --- Private ---

  defp compute_stats do
    all_providers = @retrieval_providers ++ @data_source_providers ++ @notification_providers

    counts =
      ChannelConfig
      |> where([c], c.enabled == true)
      |> group_by([c], c.provider)
      |> select([c], {c.provider, count(c.id)})
      |> Repo.all()
      |> Map.new()

    Enum.reduce(all_providers, %{}, fn provider, acc ->
      Map.put(acc, String.to_atom(provider), Map.get(counts, provider, 0))
    end)
  end

  defp compute_ingress_statuses(configured_providers)
       when is_struct(configured_providers, MapSet) do
    providers = ingress_status_providers(configured_providers)

    Enum.reduce(providers, %{}, fn provider, acc ->
      Map.put(acc, provider, fetch_ingress_status(provider))
    end)
  end

  defp ingress_status_providers(configured_providers) do
    @retrieval_cards
    |> Enum.map(& &1.id)
    |> Enum.reject(&(&1 == "email"))
    |> Enum.filter(&MapSet.member?(configured_providers, &1))
  end

  defp ingress_status_loading(configured_providers)
       when is_struct(configured_providers, MapSet) do
    configured_providers
    |> ingress_status_providers()
    |> Map.new(fn provider -> {provider, true} end)
  end

  defp schedule_ingress_status_refresh(socket, configured_providers)
       when is_struct(configured_providers, MapSet) do
    socket
    |> assign(:ingress_statuses, %{})
    |> assign(:ingress_status_loading, ingress_status_loading(configured_providers))
    |> start_async(:ingress_statuses, fn -> compute_ingress_statuses(configured_providers) end)
  end

  defp configured_retrieval_providers do
    ChannelConfig
    |> where([c], c.kind == "retrieval")
    |> select([c], c.provider)
    |> Repo.all()
    |> MapSet.new()
  end

  defp fetch_ingress_status(provider) do
    event = Event.new(%{provider: provider}, :channels, opts: [action: :channel_ingress_status])
    event |> NodeRouter.dispatch() |> Map.get(:response) |> IngressStatusUI.normalize_response()
  end
end

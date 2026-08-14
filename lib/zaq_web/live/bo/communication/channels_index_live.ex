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

  @pending_ingress_status_retry_ms 200
  @pending_ingress_status_max_attempts 25

  @retrieval_providers ~w(slack teams mattermost discord telegram webhook email)
  @data_source_providers ~w(disk google_drive sharepoint)
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
      id: "disk",
      label: "Disk",
      color: "#64748B",
      desc: "Expose documents stored on the mounted server volumes to agents."
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
  # (E2E: CHANNEL_INDEX_* in test/e2e/specs/channels.spec.js — keep in sync)
  @retrieval_preview ~w(slack teams mattermost discord telegram)
  @data_source_preview ~w(disk google_drive sharepoint)

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
     |> assign(:ingress_status_refresh_attempts, 0)
     |> assign(:ingress_status_modal, nil)
     |> schedule_ingress_status_refresh(configured_providers)}
  end

  @impl true
  def handle_async(:ingress_statuses, result, socket) do
    {:noreply,
     socket
     |> IngressStatusUI.apply_async_result(result)
     |> maybe_schedule_pending_ingress_status_refresh()}
  end

  @impl true
  def handle_info(:refresh_pending_ingress_statuses, socket) do
    {:noreply, retry_ingress_status_refresh(socket)}
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
     |> assign(:page_subtitle, page_subtitle(kind))
     |> assign(:current_path, current_path)
     |> assign(:kind, kind)
     |> assign(:cards, cards)}
  end

  attr :kind, :atom, required: true

  @doc """
  Category icon for channels sub-page headers — matches the index category cards,
  not the first provider in the grid.
  """
  def category_header_icon(assigns) do
    ~H"""
    <div
      class="w-10 h-10 rounded-xl grid place-items-center shrink-0"
      style={category_header_icon_style(@kind)}
    >
      <%= case @kind do %>
        <% :retrieval -> %>
          <svg
            class="w-6 h-6"
            fill="none"
            stroke="currentColor"
            stroke-width="1.8"
            viewBox="0 0 24 24"
            style="color: #3b82f6;"
          >
            <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
          </svg>
        <% :data_source -> %>
          <svg
            class="w-6 h-6"
            fill="none"
            stroke="currentColor"
            stroke-width="1.8"
            viewBox="0 0 24 24"
            style="color: #f59e0b;"
          >
            <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" />
            <polyline points="14 2 14 8 20 8" />
            <line x1="16" y1="13" x2="8" y2="13" />
            <line x1="16" y1="17" x2="8" y2="17" />
          </svg>
        <% :notification -> %>
          <ZaqWeb.Components.ChannelIcons.icon provider="email" class="w-6 h-6" />
      <% end %>
    </div>
    """
  end

  defp category_header_icon_style(:retrieval), do: "background-color: #eff6ff;"
  defp category_header_icon_style(:data_source), do: "background-color: #fffbeb;"

  defp category_header_icon_style(:notification),
    do: "background-color: #16a34a14; border: 1px solid #16a34a33;"

  defp category_header_icon_style(_), do: "background: var(--zaq-surface-color-base);"

  @doc "Subtitle copy for the channels index and category grid pages."
  def page_subtitle(:index),
    do: "Connect your team's communication tools to centralize messages and automate workflows."

  def page_subtitle(:retrieval),
    do: "Messaging platforms that receive user questions and return answers from ZAQ."

  def page_subtitle(:data_source),
    do: "Document sources that feed the knowledge base with files and content."

  def page_subtitle(:notification),
    do: "Outbound delivery channels for alerts, invitations, and system notifications."

  @doc "Provider card description reused on provider detail pages."
  def provider_description(provider_id) do
    (@retrieval_cards ++ @data_source_cards ++ @notification_cards)
    |> Enum.find_value(fn
      %{id: ^provider_id, desc: desc} -> desc
      _ -> nil
    end)
  end

  @doc "Brand accent colour from channel card definitions."
  def provider_accent(nil), do: nil

  def provider_accent(provider_id) do
    case provider_card(provider_id) do
      %{color: color} -> color
      _ -> nil
    end
  end

  defp provider_card(id) do
    Enum.find(@retrieval_cards ++ @data_source_cards ++ @notification_cards, &(&1.id == id))
  end

  # --- Helpers used by template ---

  # Stats are keyed by provider string — the same key `compute_stats/0` reads off
  # `channel_configs.provider`, so no atom is ever built from one.
  def stat_for(stats, "email"),
    do: Map.get(stats, "email:imap", 0) + Map.get(stats, "email:smtp", 0)

  def stat_for(stats, provider), do: Map.get(stats, provider, 0)

  def retrieval_total(stats), do: total_for(stats, @retrieval_providers)

  def data_source_total(stats), do: total_for(stats, @data_source_providers)

  def notification_total(stats), do: total_for(stats, @notification_providers)

  defp total_for(stats, providers) do
    Enum.reduce(providers, 0, fn provider, acc -> acc + Map.get(stats, provider, 0) end)
  end

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

    Map.new(all_providers, &{&1, Map.get(counts, &1, 0)})
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
    |> assign(:ingress_status_refresh_attempts, 0)
    |> start_async(:ingress_statuses, fn -> compute_ingress_statuses(configured_providers) end)
  end

  defp retry_ingress_status_refresh(socket) do
    configured_providers = socket.assigns.configured_ingress_providers

    start_async(socket, :ingress_statuses, fn ->
      compute_ingress_statuses(configured_providers)
    end)
  end

  defp maybe_schedule_pending_ingress_status_refresh(socket) do
    IngressStatusUI.maybe_schedule_pending_refresh(
      socket,
      :refresh_pending_ingress_statuses,
      @pending_ingress_status_retry_ms,
      @pending_ingress_status_max_attempts
    )
  end

  defp configured_retrieval_providers do
    ChannelConfig
    |> where([c], c.kind == "retrieval" and c.enabled == true)
    |> select([c], c.provider)
    |> Repo.all()
    |> MapSet.new()
  end

  defp fetch_ingress_status(provider) do
    event = Event.new(%{provider: provider}, :channels, opts: [action: :channel_ingress_status])
    event |> NodeRouter.dispatch() |> Map.get(:response) |> IngressStatusUI.normalize_response()
  end
end

defmodule ZaqWeb.Live.BO.Communication.NotificationLogsLive do
  @moduledoc """
  BO LiveView for browsing notification audit logs.

  Paginated table of all `notification_logs` rows, ordered newest-first.
  A "View more" modal shows the full payload (subject + body) for a row.
  """

  use ZaqWeb, :live_view

  import Ecto.Query

  alias Zaq.Engine.Notifications.NotificationLog
  alias Zaq.Repo
  alias ZaqWeb.Components.ServiceUnavailable

  @per_page 20
  @required_roles [:channels]

  @impl true
  def mount(_params, _session, socket) do
    available = ServiceUnavailable.available?(@required_roles)

    socket =
      socket
      |> assign(:page_title, "Notification Logs")
      |> assign(:current_path, "/bo/channels/notifications/logs")
      |> assign(:service_available, available)
      |> assign(:required_roles, @required_roles)
      |> assign(:page, 1)
      |> assign(:per_page, @per_page)
      |> assign(:selected_log, nil)

    socket = if available, do: load_logs(socket), else: socket

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("next_page", _params, socket) do
    total_pages = ceil(socket.assigns.total / socket.assigns.per_page)

    socket =
      if socket.assigns.page < total_pages do
        socket |> assign(:page, socket.assigns.page + 1) |> load_logs()
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("prev_page", _params, socket) do
    socket =
      if socket.assigns.page > 1 do
        socket |> assign(:page, socket.assigns.page - 1) |> load_logs()
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("view_log", %{"id" => id}, socket) do
    log = Repo.get(NotificationLog, id)
    {:noreply, assign(socket, :selected_log, log)}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :selected_log, nil)}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp load_logs(socket) do
    page = socket.assigns.page
    per_page = socket.assigns.per_page
    offset = (page - 1) * per_page

    total = Repo.aggregate(NotificationLog, :count)

    logs =
      from(l in NotificationLog,
        order_by: [desc: l.inserted_at],
        limit: ^per_page,
        offset: ^offset
      )
      |> Repo.all()

    socket
    |> assign(:logs, logs)
    |> assign(:total, total)
  end
end

defmodule ZaqWeb.Live.People.HistoryLive do
  @moduledoc "Paginated literal-owned history using the shared BO history browser."
  use ZaqWeb, :live_view
  alias ZaqWeb.Components.DesignSystem.{HistoryBrowser, PersonHeader}
  alias ZaqWeb.Components.PersonLayout
  alias ZaqWeb.Live.People.ConversationAccess, as: Access

  @impl true
  def mount(_, session, socket) do
    {:ok,
     socket
     |> put_private(:person_conversation_token, session["person_session_token"])
     |> assign(
       page_title: "Conversations",
       conversations: [],
       total: 0,
       page: 1,
       filters: Access.list_params(%{})
     )}
  end

  @impl true
  def handle_params(params, _, socket), do: {:noreply, load(socket, Access.list_params(params))}

  @impl true
  def handle_event(event, params, socket) do
    socket = load(socket, socket.assigns.filters)

    if socket.redirected do
      {:noreply, socket}
    else
      filters =
        case event do
          "filter" ->
            Map.merge(socket.assigns.filters, Map.take(params, ["status", "channel_type"]))
            |> Map.put("page", "1")

          "change_page" ->
            Map.put(socket.assigns.filters, "page", params["page"])

          _ ->
            socket.assigns.filters
        end

      {:noreply,
       push_patch(socket, to: "/people/history?" <> URI.encode_query(Access.list_params(filters)))}
    end
  end

  defp load(socket, filters) do
    case Access.command(socket, :list, %{
           status: filters["status"],
           channel_type: filters["channel_type"],
           page: filters["page"]
         }) do
      {:ok, data} ->
        assign(socket,
          conversations: data.conversations,
          total: data.total,
          page: data.page,
          filters: Map.put(filters, "page", to_string(data.page)),
          person_permissions: data.permissions,
          current_person: Map.merge(socket.assigns.current_person, data.person)
        )

      {:error, reason} ->
        Access.denied(socket, reason)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PersonLayout.person_layout flash={@flash} authenticated content_width={:wide}>
      <:header>
        <PersonHeader.person_header
          title="Conversations"
          display_name={@current_person.full_name}
          person_permissions={@person_permissions}
        />
      </:header>
      <HistoryBrowser.history_browser
        conversations={@conversations}
        conversation_count={@total}
        status={@filters["status"]}
        filter_channel_type={@filters["channel_type"]}
        page={@page}
        status_options={[{"All", "all"}, {"Active", "active"}, {"Archived", "archived"}]}
        selectable={false}
        actions={false}
        destination={fn id -> "/people/conversations/#{id}?" <> URI.encode_query(@filters) end}
      />
    </PersonLayout.person_layout>
    """
  end
end

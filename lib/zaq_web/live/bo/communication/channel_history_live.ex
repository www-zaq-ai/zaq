defmodule ZaqWeb.Live.BO.Communication.ChannelHistoryLive do
  @moduledoc """
  BO administration of persisted communication-channel transcripts.

  The Engine verifies the current BO user's super-admin role on every
  confidential read. This LiveView never queries a Repo or accepts a Person
  identity from the browser as authority.
  """

  use ZaqWeb, :live_view

  alias Zaq.Event
  alias Zaq.NodeRouter
  alias ZaqWeb.Components.{BOModal, ChannelIcons, ChatMessage, PersonAvatar}
  alias ZaqWeb.Live.BO.Communication.MessageHelpers

  alias ZaqWeb.Components.DesignSystem.{
    Breadcrumb,
    Button,
    CardShell,
    ConversationDetail,
    EmptyState,
    Input,
    Table
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_path, "/bo/channels/history")
     |> assign(:show_access, false)
     |> assign(:message_info_id, nil)
     |> assign(:message_info, MessageHelpers.empty_message_info())
     |> assign(:expanded_trace_ids, MapSet.new())
     |> assign(:search, "")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    screen = if socket.assigns.live_action == :show, do: :detail, else: :list
    user = socket.assigns.current_user

    socket =
      socket
      |> assign(:screen, screen)
      |> assign(:parent_id, params["channel"])
      |> assign(
        :page_title,
        if(screen == :detail, do: "Channel transcript", else: "Channel history")
      )

    case screen do
      :list ->
        offset = parse_cursor(params["offset"])
        response = dispatch(user, %{op: :list, offset: offset, parent_id: params["channel"]})

        {:noreply,
         socket
         |> assign(:list_offset, offset)
         |> assign(:result, response)
         |> assign(:detail, nil)}

      :detail ->
        cursor = parse_cursor(params["after"])
        response = dispatch(user, %{op: :detail, id: params["id"], cursor: cursor})

        {:noreply,
         socket
         |> assign(:detail_cursor, cursor)
         |> assign(:result, response)
         |> assign(:detail, response)}
    end
  end

  @impl true
  def handle_event("filter", %{"filter" => %{"query" => query}}, socket) when is_binary(query) do
    {:noreply, assign(socket, :search, String.slice(query, 0, 100))}
  end

  def handle_event("filter", _params, socket), do: {:noreply, socket}

  def handle_event("open_access", _params, socket),
    do: {:noreply, assign(socket, :show_access, true)}

  def handle_event("close_access", _params, socket),
    do: {:noreply, assign(socket, :show_access, false)}

  def handle_event("copy_message", %{"text" => text}, socket),
    do: {:noreply, push_event(socket, "clipboard", %{text: text})}

  def handle_event("open_message_info", %{"id" => id}, socket) do
    case message_request(socket, %{op: :message_info, message_id: id}) do
      {:ok, message} ->
        {:noreply,
         socket
         |> assign(:message_info_id, id)
         |> assign(:message_info, MessageHelpers.message_info_from_message(message))
         |> assign(:expanded_trace_ids, MapSet.new())}

      _ ->
        {:noreply, put_flash(socket, :error, "Message information unavailable")}
    end
  end

  def handle_event("close_message_info", _params, socket),
    do: {:noreply, assign(socket, :message_info_id, nil)}

  def handle_event("toggle_trace", %{"trace_id" => id}, socket),
    do:
      {:noreply,
       assign(
         socket,
         :expanded_trace_ids,
         MessageHelpers.toggle_trace_details(socket.assigns.expanded_trace_ids, id)
       )}

  def handle_event("feedback", %{"id" => id, "type" => type}, socket)
      when type in ["positive", "negative"] do
    rating = if type == "positive", do: 5, else: 1

    case message_request(socket, %{op: :rate, message_id: id, rating: rating}) do
      {:ok, _} ->
        response = message_request(socket, %{op: :detail, cursor: socket.assigns.detail_cursor})
        {:noreply, socket |> assign(:result, response) |> assign(:detail, response)}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not save feedback")}
    end
  end

  def handle_event("grant", %{"grant" => %{"person_id" => value}}, socket) do
    mutate_access(socket, :grant, value)
  end

  def handle_event("revoke", %{"id" => value}, socket) do
    mutate_access(socket, :revoke, value)
  end

  def handle_event(
        "refresh",
        _params,
        %{assigns: %{detail: {:ok, %{transcript: transcript}}}} = socket
      ) do
    if transcript.refresh_supported? do
      case dispatch(socket.assigns.current_user, %{op: :refresh, id: transcript.id}) do
        {:ok, %{members: count}} ->
          {:noreply,
           socket
           |> assign(
             :detail,
             dispatch(socket.assigns.current_user, %{op: :detail, id: transcript.id})
           )
           |> put_flash(:info, "Provider access refreshed (#{count} linked People)")}

        {:error, _} ->
          {:noreply,
           put_flash(socket, :error, "Provider access unchanged: refresh failed or incomplete")}
      end
    else
      {:noreply, put_flash(socket, :error, "Provider refresh is unsupported for this transcript")}
    end
  end

  def handle_event("refresh", _params, socket), do: {:noreply, socket}

  defp mutate_access(
         %{assigns: %{detail: {:ok, %{transcript: transcript}}}} = socket,
         operation,
         value
       ) do
    result =
      case value do
        value when is_binary(value) ->
          case Integer.parse(value) do
            {person_id, ""} when person_id > 0 ->
              dispatch(socket.assigns.current_user, %{
                op: operation,
                id: transcript.id,
                person_id: person_id
              })

            _ ->
              {:error, :invalid_person}
          end

        _ ->
          {:error, :invalid_person}
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(
           :detail,
           dispatch(socket.assigns.current_user, %{op: :detail, id: transcript.id})
         )
         |> put_flash(:info, "Manual access updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update manual access")}
    end
  end

  defp mutate_access(socket, _operation, _value), do: {:noreply, socket}

  defp message_request(%{assigns: %{detail: {:ok, %{transcript: transcript}}}} = socket, request),
    do: dispatch(socket.assigns.current_user, Map.put(request, :id, transcript.id))

  defp message_request(_, _), do: {:error, :not_found}

  defp dispatch(user, request) do
    Event.new(request, :engine,
      actor: %{user_id: user.id},
      opts: [action: :channel_history_admin, confidential: true]
    )
    |> NodeRouter.dispatch()
    |> Map.get(:response)
  end

  defp parse_cursor(nil), do: 0

  defp parse_cursor(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> number
      _ -> -1
    end
  end

  defp parse_cursor(_), do: -1

  defp filtered_rows(rows, search) do
    needle = String.downcase(search)

    Enum.filter(rows, fn row ->
      Enum.any?([row.channel_name, row.connector, row.channel_id, row.provider], fn text ->
        is_binary(text) and String.contains?(String.downcase(text), needle)
      end)
    end)
  end

  defp next_cursor([]), do: 0
  defp next_cursor(messages), do: List.last(messages).position

  defp page_params(nil, offset), do: %{offset: offset}
  defp page_params(parent, offset), do: %{offset: offset, channel: parent}

  defp root_preview(nil), do: "Root message unavailable"
  defp root_preview(%{content: text}) when text in [nil, ""], do: "Attachment"
  defp root_preview(%{content: text}), do: String.slice(text, 0, 120)

  defp header_context({:ok, %{transcript: transcript}}), do: transcript
  defp header_context(_), do: nil

  defp history_breadcrumbs(:list, {:ok, %{parent: %{id: id, channel_name: name}}}) do
    [history_crumb(), channel_crumb(id, name), %{label: "Threads", current: true}]
  end

  defp history_breadcrumbs(:detail, {:ok, %{transcript: %{parent_id: nil} = transcript}}) do
    [history_crumb(), %{label: transcript.channel_name, current: true}]
  end

  defp history_breadcrumbs(:detail, {:ok, %{transcript: transcript, root_message: root}}) do
    [
      history_crumb(),
      channel_crumb(transcript.parent_id, transcript.channel_name),
      %{label: "Threads", to: ~p"/bo/channels/history?channel=#{transcript.parent_id}"},
      %{label: if(root, do: root_preview(root), else: "Thread"), current: true}
    ]
  end

  defp history_breadcrumbs(_, _), do: []
  defp history_crumb, do: %{label: "Channel history", to: ~p"/bo/channels/history"}
  defp channel_crumb(id, name), do: %{label: name, to: ~p"/bo/channels/history/#{id}"}

  defp timeline_messages(nil, messages), do: messages

  defp timeline_messages(root, messages) do
    [
      Map.put(root, :root_context?, true)
      | Enum.reject(messages, &(&1.message_id == root.message_id))
    ]
  end
end

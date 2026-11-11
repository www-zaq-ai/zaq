defmodule ZaqWeb.Live.BO.Communication.ChannelHistoryLive do
  @moduledoc """
  BO administration of persisted communication-channel transcripts.

  The Engine verifies the current BO user's super-admin role on every
  confidential read. This LiveView never queries a Repo or accepts a Person
  identity from the browser as authority.
  Scoped PubSub messages are UI invalidation hints only. Their handlers reread
  authorized persisted rows and never perform delivery or history mutations.
  """

  use ZaqWeb, :live_view

  alias Zaq.Event
  alias Zaq.NodeRouter
  alias ZaqWeb.Components.{BOModal, ChannelIcons, ChatMessage, PersonAvatar}
  alias ZaqWeb.History.ChannelTimeline
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
     |> assign(:delivery_info, nil)
     |> assign(:history_subscription, nil)
     |> assign(:history_update_ids, MapSet.new())
     |> assign(:history_update_scheduled, false)
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
         |> unsubscribe_history()
         |> assign(:list_offset, offset)
         |> assign(:result, response)
         |> assign(:detail, nil)}

      :detail ->
        cursor = parse_cursor(params["after"])

        {socket, response} =
          case subscribe_history(socket, params["id"]) do
            {:ok, subscribed} ->
              {subscribed, dispatch(user, %{op: :detail, id: params["id"], cursor: cursor})}

            {:error, reason, unsubscribed} ->
              {unsubscribed, {:error, reason}}
          end

        {:noreply,
         socket
         |> assign(:detail_cursor, cursor)
         |> assign_detail(response)}
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

      error ->
        {:noreply, history_error(socket, error, "Message information unavailable")}
    end
  end

  def handle_event("close_message_info", _params, socket),
    do: {:noreply, assign(socket, :message_info_id, nil)}

  def handle_event("open_delivery_info", %{"id" => id}, socket) do
    case message_request(socket, %{op: :message_changes, message_ids: [id]}) do
      {:ok, changes} ->
        socket = apply_history_changes(socket, changes)
        message = Enum.find(changes.pending_messages, &(&1.message_id == id))
        {:noreply, assign(socket, :delivery_info, message)}

      error ->
        {:noreply, history_error(socket, error, "Delivery information unavailable")}
    end
  end

  def handle_event("close_delivery_info", _params, socket),
    do: {:noreply, assign(socket, :delivery_info, nil)}

  def handle_event(
        "load_pending",
        _params,
        %{assigns: %{detail: {:ok, %{pending_has_more: true} = detail}}} = socket
      ) do
    request = %{
      op: :detail,
      cursor: socket.assigns.detail_cursor,
      pending_cursor: detail.pending_next_cursor
    }

    case message_request(socket, request) do
      {:ok, page} ->
        {:noreply,
         assign_detail(socket, {:ok, ChannelTimeline.append_pending_page(detail, page)})}

      error ->
        {:noreply, history_error(socket, error, "Outstanding messages unavailable")}
    end
  end

  def handle_event("load_pending", _params, socket), do: {:noreply, socket}

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

    with {:ok, _} <- message_request(socket, %{op: :rate, message_id: id, rating: rating}),
         {:ok, changes} <- message_request(socket, %{op: :message_changes, message_ids: [id]}) do
      {:noreply, apply_history_changes(socket, changes)}
    else
      error -> {:noreply, history_error(socket, error, "Could not save feedback")}
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
           refresh_history_context(socket, "Provider access refreshed (#{count} linked People)")}

        error ->
          {:noreply,
           history_error(socket, error, "Provider access unchanged: refresh failed or incomplete")}
      end
    else
      {:noreply, put_flash(socket, :error, "Provider refresh is unsupported for this transcript")}
    end
  end

  def handle_event("refresh", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:channel_history_updated, id, ids}, socket) when is_list(ids) do
    if socket.assigns.history_subscription && socket.assigns.history_subscription.id == id do
      updates = ids |> Enum.filter(&is_binary/1) |> MapSet.new()

      unless socket.assigns.history_update_scheduled, do: send(self(), :flush_history_updates)

      {:noreply,
       socket
       |> assign(:history_update_ids, MapSet.union(socket.assigns.history_update_ids, updates))
       |> assign(:history_update_scheduled, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:flush_history_updates, %{assigns: %{detail: {:ok, detail}}} = socket) do
    ids = MapSet.to_list(socket.assigns.history_update_ids)

    socket =
      socket
      |> assign(:history_update_ids, MapSet.new())
      |> assign(:history_update_scheduled, false)

    result =
      ids
      |> Enum.chunk_every(50)
      |> Enum.reduce_while({:ok, detail}, fn batch, {:ok, current} ->
        case message_request(socket, %{op: :message_changes, message_ids: batch}) do
          {:ok, changes} ->
            {:cont,
             {:ok, ChannelTimeline.merge_changes(current, changes, socket.assigns.detail_cursor)}}

          error ->
            {:halt, error}
        end
      end)

    case result do
      {:ok, updated} ->
        {:noreply, socket |> assign_detail({:ok, updated}) |> update_delivery_info(updated)}

      {:error, :unauthorized} ->
        {:noreply, assign_detail(socket, {:error, :unauthorized})}

      _ ->
        {:noreply,
         put_flash(socket, :error, "Realtime update unavailable. Reload to refresh history.")}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp subscribe_history(socket, id) do
    cond do
      socket.assigns.history_subscription && socket.assigns.history_subscription.id == id ->
        {:ok, socket}

      not connected?(socket) ->
        {:ok, socket}

      true ->
        socket = unsubscribe_history(socket)

        case dispatch(socket.assigns.current_user, %{op: :subscription, id: id}) do
          {:ok, %{topic: topic}} ->
            Phoenix.PubSub.subscribe(Zaq.PubSub, topic)
            {:ok, assign(socket, :history_subscription, %{id: id, topic: topic})}

          {:error, reason} ->
            {:error, reason, socket}
        end
    end
  end

  defp unsubscribe_history(socket) do
    if subscription = socket.assigns.history_subscription do
      Phoenix.PubSub.unsubscribe(Zaq.PubSub, subscription.topic)
    end

    socket
    |> assign(:history_subscription, nil)
    |> assign(:history_update_ids, MapSet.new())
    |> assign(:history_update_scheduled, false)
    |> assign(:delivery_info, nil)
  end

  defp assign_detail(socket, {:ok, _} = response),
    do: socket |> assign(:detail, response) |> assign(:result, response)

  defp assign_detail(socket, response) do
    socket
    |> unsubscribe_history()
    |> assign(:detail, response)
    |> assign(:result, response)
    |> assign(:message_info_id, nil)
    |> assign(:message_info, MessageHelpers.empty_message_info())
    |> assign(:expanded_trace_ids, MapSet.new())
    |> assign(:show_access, false)
  end

  defp history_error(socket, {:error, :unauthorized} = error, _message),
    do: assign_detail(socket, error)

  defp history_error(socket, _error, message), do: put_flash(socket, :error, message)

  defp refresh_history_context(%{assigns: %{detail: {:ok, detail}}} = socket, message) do
    case message_request(socket, %{op: :detail, cursor: socket.assigns.detail_cursor}) do
      {:ok, refreshed} ->
        updated = Map.merge(detail, Map.take(refreshed, [:transcript, :grants, :root_message]))
        socket |> assign_detail({:ok, updated}) |> put_flash(:info, message)

      error ->
        history_error(socket, error, "History information unavailable")
    end
  end

  defp apply_history_changes(%{assigns: %{detail: {:ok, detail}}} = socket, changes) do
    updated = ChannelTimeline.merge_changes(detail, changes, socket.assigns.detail_cursor)
    socket |> assign_detail({:ok, updated}) |> update_delivery_info(updated)
  end

  defp update_delivery_info(%{assigns: %{delivery_info: nil}} = socket, _detail), do: socket

  defp update_delivery_info(socket, detail) do
    selected = socket.assigns.delivery_info

    message =
      Enum.find(detail.pending_messages, &(&1.message_id == selected.message_id)) ||
        confirmed_delivery_info(selected, detail.messages)

    assign(socket, :delivery_info, message)
  end

  defp confirmed_delivery_info(selected, messages) do
    if Enum.any?(messages, &(&1.message_id == selected.message_id)) do
      %{selected | delivery: %{state: :delivered, reason: "The provider confirmed delivery."}}
    end
  end

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
        {:noreply, refresh_history_context(socket, "Manual access updated")}

      error ->
        {:noreply, history_error(socket, error, "Could not update manual access")}
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

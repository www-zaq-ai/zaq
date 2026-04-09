defmodule ZaqWeb.Live.BO.Communication.HistoryLive do
  @moduledoc """
  Conversation history page.

  - `/bo/history`          — active conversations
  - `/bo/history/archived` — archived conversations

  All authenticated users can see their own history.
  Super-admins can switch to an "All Users" scope with additional
  identity, team, person, and channel filters.

  Supports per-row delete/archive and bulk select → archive/delete.
  """

  use ZaqWeb, :live_view

  import ZaqWeb.Components.SearchableSelect

  alias Zaq.Accounts.People
  alias Zaq.NodeRouter

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns[:current_user]
    is_admin = super_admin?(current_user)

    {:ok,
     socket
     |> assign(:current_path, "/bo/history")
     |> assign(:is_admin, is_admin)
     |> assign(:conversations, [])
     |> assign(:selected, MapSet.new())
     |> assign(:filter_scope, "own")
     |> assign(:filter_channel_type, "all")
     |> assign(:filter_team_id, "all")
     |> assign(:filter_person_id, "all")
     |> assign(:teams, People.list_teams())
     |> assign(:people, [])}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    status =
      case socket.assigns.live_action do
        :archived -> "archived"
        _ -> "active"
      end

    page_title = if status == "archived", do: "Archived History", else: "History"
    current_user = socket.assigns[:current_user]
    user_id = current_user && current_user.id

    opts =
      [{:status, status}]
      |> then(fn o ->
        if socket.assigns.filter_scope == "own", do: [{:user_id, user_id} | o], else: o
      end)
      |> maybe_filter(:channel_type, socket.assigns.filter_channel_type)
      |> maybe_filter_int(:team_id, socket.assigns.filter_team_id)
      |> maybe_filter_int(:person_id, socket.assigns.filter_person_id)

    {:noreply,
     socket
     |> assign(:page_title, page_title)
     |> assign(:status, status)
     |> assign(:selected, MapSet.new())
     |> assign(:conversations, load_conversations(opts))}
  end

  @impl true
  def handle_event("filter", params, socket) do
    current_user = socket.assigns[:current_user]
    user_id = current_user && current_user.id

    scope =
      if socket.assigns.is_admin,
        do: Map.get(params, "scope", socket.assigns.filter_scope),
        else: "own"

    channel_type = Map.get(params, "channel_type", socket.assigns.filter_channel_type)

    team_id =
      if scope == "all",
        do: Map.get(params, "team_id", socket.assigns.filter_team_id),
        else: "all"

    person_id =
      if scope == "all",
        do: Map.get(params, "person_id", socket.assigns.filter_person_id),
        else: "all"

    opts =
      [{:status, socket.assigns.status}]
      |> then(fn o -> if scope == "own", do: [{:user_id, user_id} | o], else: o end)
      |> maybe_filter(:channel_type, channel_type)
      |> maybe_filter_int(:team_id, team_id)
      |> maybe_filter_int(:person_id, person_id)

    {:noreply,
     socket
     |> assign(:conversations, load_conversations(opts))
     |> assign(:filter_scope, scope)
     |> assign(:filter_channel_type, channel_type)
     |> assign(:filter_team_id, team_id)
     |> assign(:filter_person_id, person_id)
     |> assign(:selected, MapSet.new())}
  end

  def handle_event("search_people", %{"query" => query}, socket) do
    {:noreply, assign(socket, :people, People.search_people(query, [], 20))}
  end

  def handle_event("toggle_select", %{"id" => id}, socket) do
    selected =
      if MapSet.member?(socket.assigns.selected, id),
        do: MapSet.delete(socket.assigns.selected, id),
        else: MapSet.put(socket.assigns.selected, id)

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("select_all", _params, socket) do
    all_ids = Enum.map(socket.assigns.conversations, & &1.id) |> MapSet.new()

    selected =
      if MapSet.equal?(socket.assigns.selected, all_ids),
        do: MapSet.new(),
        else: all_ids

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("archive_conversation", %{"id" => id}, socket) do
    NodeRouter.call(:engine, Zaq.Engine.Conversations, :archive_conversation_by_id, [id])
    {:noreply, remove_conversations(socket, [id])}
  end

  def handle_event("delete_conversation", %{"id" => id}, socket) do
    NodeRouter.call(:engine, Zaq.Engine.Conversations, :delete_conversation_by_id, [id])
    {:noreply, remove_conversations(socket, [id])}
  end

  def handle_event("bulk_archive", _params, socket) do
    ids = MapSet.to_list(socket.assigns.selected)

    {successful_ids, failed_count} =
      Enum.reduce(ids, {[], 0}, fn id, {ok_ids, fail_count} ->
        case NodeRouter.call(:engine, Zaq.Engine.Conversations, :archive_conversation_by_id, [id]) do
          :ok -> {[id | ok_ids], fail_count}
          _ -> {ok_ids, fail_count + 1}
        end
      end)

    socket =
      socket
      |> remove_conversations(successful_ids)
      |> then(fn s ->
        if failed_count > 0,
          do: put_flash(s, :error, "Failed to archive #{failed_count} conversation(s)"),
          else: s
      end)

    {:noreply, socket}
  end

  def handle_event("bulk_delete", _params, socket) do
    ids = MapSet.to_list(socket.assigns.selected)

    {successful_ids, failed_count} =
      Enum.reduce(ids, {[], 0}, fn id, {ok_ids, fail_count} ->
        case NodeRouter.call(:engine, Zaq.Engine.Conversations, :delete_conversation_by_id, [id]) do
          :ok -> {[id | ok_ids], fail_count}
          _ -> {ok_ids, fail_count + 1}
        end
      end)

    socket =
      socket
      |> remove_conversations(successful_ids)
      |> then(fn s ->
        if failed_count > 0,
          do: put_flash(s, :error, "Failed to delete #{failed_count} conversation(s)"),
          else: s
      end)

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp remove_conversations(socket, ids) do
    id_set = MapSet.new(ids)

    socket
    |> assign(
      :conversations,
      Enum.reject(socket.assigns.conversations, &MapSet.member?(id_set, &1.id))
    )
    |> assign(:selected, MapSet.difference(socket.assigns.selected, id_set))
  end

  defp load_conversations(opts) do
    result = NodeRouter.call(:engine, Zaq.Engine.Conversations, :list_conversations, [opts])
    if is_list(result), do: result, else: []
  end

  defp super_admin?(%{role: %{name: "super_admin"}}), do: true
  defp super_admin?(_), do: false

  defp maybe_filter(opts, _key, "all"), do: opts
  defp maybe_filter(opts, key, value), do: [{key, value} | opts]

  defp maybe_filter_int(opts, _key, "all"), do: opts
  defp maybe_filter_int(opts, _key, ""), do: opts
  defp maybe_filter_int(opts, _key, nil), do: opts

  defp maybe_filter_int(opts, key, value) when is_binary(value),
    do: maybe_filter_int(opts, key, Integer.parse(value))

  defp maybe_filter_int(opts, key, {int, _}), do: [{key, int} | opts]
  defp maybe_filter_int(opts, _key, :error), do: opts
end

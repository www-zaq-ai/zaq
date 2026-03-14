defmodule ZaqWeb.Live.BO.Communication.HistoryLive do
  @moduledoc """
  Conversation history page.

  All authenticated users can see their own conversation history.
  Super-admins can switch to an "All Users" scope to inspect every
  conversation in the system, with additional identity and channel filters.
  """

  use ZaqWeb, :live_view

  alias Zaq.NodeRouter

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns[:current_user]
    is_admin = super_admin?(current_user)
    user_id = current_user && current_user.id

    conversations = load_conversations(user_id: user_id)

    {:ok,
     socket
     |> assign(:page_title, "History")
     |> assign(:current_path, "/bo/history")
     |> assign(:is_admin, is_admin)
     |> assign(:conversations, conversations)
     |> assign(:filter_scope, "own")
     |> assign(:filter_status, "all")
     |> assign(:filter_channel_type, "all")}
  end

  @impl true
  def handle_event("filter", params, socket) do
    current_user = socket.assigns[:current_user]
    user_id = current_user && current_user.id

    scope =
      if socket.assigns.is_admin,
        do: Map.get(params, "scope", socket.assigns.filter_scope),
        else: "own"

    status = Map.get(params, "status", socket.assigns.filter_status)
    channel_type = Map.get(params, "channel_type", socket.assigns.filter_channel_type)

    opts =
      []
      |> then(fn o -> if scope == "own", do: [{:user_id, user_id} | o], else: o end)
      |> maybe_filter(:status, status)
      |> maybe_filter(:channel_type, channel_type)

    {:noreply,
     socket
     |> assign(:conversations, load_conversations(opts))
     |> assign(:filter_scope, scope)
     |> assign(:filter_status, status)
     |> assign(:filter_channel_type, channel_type)}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp load_conversations(opts) do
    result = NodeRouter.call(:engine, Zaq.Engine.Conversations, :list_conversations, [opts])
    if is_list(result), do: result, else: []
  end

  defp super_admin?(%{role: %{name: "super_admin"}}), do: true
  defp super_admin?(_), do: false

  defp maybe_filter(opts, _key, "all"), do: opts
  defp maybe_filter(opts, key, value), do: [{key, value} | opts]
end

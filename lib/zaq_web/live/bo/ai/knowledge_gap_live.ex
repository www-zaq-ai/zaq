defmodule ZaqWeb.Live.BO.AI.KnowledgeGapLive do
  @moduledoc """
  BackOffice LiveView for the Knowledge Gap Detection feature.

  Gated behind add-on checks — shows "Feature Not Enabled" until the
  Knowledge Gap Detection feature is included in the loaded add-ons.
  """
  use ZaqWeb, :live_view

  alias Zaq.Addons.FeatureStore

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Zaq.PubSub, "addons:updated")
    end

    {:ok,
     socket
     |> assign(:current_path, "/bo/knowledge-gap")
     |> assign(:enabled, FeatureStore.feature_loaded?("knowledge_gap"))}
  end

  @impl true
  def handle_info(:addons_updated, socket) do
    {:noreply, assign(socket, :enabled, FeatureStore.feature_loaded?("knowledge_gap"))}
  end
end

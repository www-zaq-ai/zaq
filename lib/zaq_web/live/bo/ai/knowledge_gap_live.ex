defmodule ZaqWeb.Live.BO.AI.KnowledgeGapLive do
  @moduledoc """
  BackOffice LiveView for the Knowledge Gap Detection feature.

  Gated behind license check — shows "Feature Not Licensed" until the
  Knowledge Gap Detection feature is included in a loaded license.
  """
  use ZaqWeb, :live_view

  alias Zaq.License.FeatureStore

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Zaq.PubSub, "license:updated")
    end

    {:ok,
     socket
     |> assign(:current_path, "/bo/knowledge-gap")
     |> assign(:licensed, FeatureStore.feature_loaded?("knowledge_gap"))}
  end

  @impl true
  def handle_info(:license_updated, socket) do
    {:noreply, assign(socket, :licensed, FeatureStore.feature_loaded?("knowledge_gap"))}
  end
end

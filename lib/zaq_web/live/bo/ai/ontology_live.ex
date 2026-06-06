defmodule ZaqWeb.Live.BO.AI.OntologyLive do
  @moduledoc """
  BackOffice LiveView for the Ontology feature.

  Displays organizational structure data loaded via the ontology add-on.
  Gated behind add-on checks — shows "Feature not enabled" if ontology
  feature is not loaded.

  IMPORTANT: All LicenseManager.Paid.Ontology.* modules are injected at runtime
  by PostLoader. They do NOT exist at compile time. Every call must use
  apply/3 or go through context module attributes — never reference structs
  directly (no %Module{} literals, no Module.function() in function heads).

  Has 3 tabs:
  - Org Structure: Businesses → Divisions → Departments → Teams (full CRUD)
  - People & Channels: People with preferred channels and team memberships (full CRUD)
  - Knowledge Domains: Knowledge domains with linked departments (full CRUD)
  """
  # Ontology modules are injected at runtime by PostLoader and do not
  # exist at compile time. apply/3 is the only safe way to call them.
  # credo:disable-for-this-file Credo.Check.Refactor.Apply
  use ZaqWeb, :live_view

  alias Zaq.Addons.FeatureStore

  @impl true
  def mount(_params, _session, socket) do
    # Check if the ontology feature is enabled by the loaded add-ons.
    enabled = FeatureStore.feature_loaded?("ontology")

    socket =
      socket
      |> assign(:current_path, "/bo/ontology")
      |> assign(:enabled, enabled)

    if enabled do
      {:ok, socket}
    else
      {:ok, assign(socket, :loading, false)}
    end
  end
end

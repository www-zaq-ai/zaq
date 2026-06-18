defmodule Storybook.Dashboard.ServicesStatusTable do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Dashboard.ServicesStatusTable

  def description,
    do:
      "BO Dashboard — services grid column with status pills (`ZaqWeb.Dashboard.ServicesStatusTable`)."

  def render(assigns) do
    assigns =
      assigns
      |> assign(:all_running, sample_services(:all_running))
      |> assign(:mixed, sample_services(:mixed))

    ~H"""
    <div
      class="zaq-text-body flex flex-col gap-12"
      style="padding: var(--zaq-scale-32); max-width: 960px;"
    >
      <div>
        <p
          class="zaq-text-caption"
          style="color: var(--zaq-text-color-body-tertiary); margin-bottom: var(--zaq-scale-16);"
        >
          All services running (single-node demo).
        </p>
        <div class="grid grid-cols-3 gap-6">
          <.services_status_table services={@all_running} />
        </div>
      </div>
      <div>
        <p
          class="zaq-text-caption"
          style="color: var(--zaq-text-color-body-tertiary); margin-bottom: var(--zaq-scale-16);"
        >
          Mixed — Engine disabled, others running.
        </p>
        <div class="grid grid-cols-3 gap-6">
          <.services_status_table services={@mixed} />
        </div>
      </div>
    </div>
    """
  end

  defp sample_services(:all_running) do
    node = :"zaq@127.0.0.1"
    Enum.map(service_rows(), &Map.merge(&1, %{active: true, node: node}))
  end

  defp sample_services(:mixed) do
    node = :"zaq@127.0.0.1"

    Enum.map(service_rows(), fn
      %{name: "Engine"} = row -> %{row | active: false, node: nil}
      row -> %{row | active: true, node: node}
    end)
  end

  defp service_rows do
    [
      %{name: "Engine", role: :engine, description: "Sessions, ontology, API routing"},
      %{name: "Agent", role: :agent, description: "RAG, LLM, classifier"},
      %{name: "Ingestion", role: :ingestion, description: "Document processing, embeddings"},
      %{name: "Channels", role: :channels, description: "Mattermost, Slack, Email"},
      %{name: "Back Office", role: :bo, description: "Admin panel (LiveView)"}
    ]
  end
end

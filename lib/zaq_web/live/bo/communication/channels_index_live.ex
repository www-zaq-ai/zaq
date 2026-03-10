defmodule ZaqWeb.Live.BO.Communication.ChannelsIndexLive do
  use ZaqWeb, :live_view

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Repo
  alias ZaqWeb.Components.ServiceUnavailable

  import Ecto.Query

  @providers ~w(slack teams mattermost ai_agents discord telegram webhook)

  # Required roles for this page — just :channels for now.
  # When ingestion channels are separated: [:channels, :ingestion]
  # When retrieval channels are separated: [:channels, :agent]
  @required_roles [:channels]

  @impl true
  def mount(_params, _session, socket) do
    available = ServiceUnavailable.available?(@required_roles)

    {:ok,
     socket
     |> assign(:page_title, "Channels")
     |> assign(:current_path, "/bo/channels")
     |> assign(:service_available, available)
     |> assign(:required_roles, @required_roles)
     |> assign(:stats, if(available, do: compute_stats(), else: %{}))}
  end

  # --- Private ---

  defp compute_stats do
    counts =
      ChannelConfig
      |> where([c], c.enabled == true)
      |> group_by([c], c.provider)
      |> select([c], {c.provider, count(c.id)})
      |> Repo.all()
      |> Map.new()

    Enum.reduce(@providers, %{}, fn provider, acc ->
      Map.put(acc, String.to_atom(provider), Map.get(counts, provider, 0))
    end)
  end
end

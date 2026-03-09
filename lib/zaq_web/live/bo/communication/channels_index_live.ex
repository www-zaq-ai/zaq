defmodule ZaqWeb.Live.BO.Communication.ChannelsIndexLive do
  use ZaqWeb, :live_view

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Repo

  import Ecto.Query

  @providers ~w(slack teams mattermost ai_agents discord telegram webhook)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Channels")
     |> assign(:current_path, "/bo/channels")
     |> assign(:stats, compute_stats())}
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

defmodule Zaq.Application do
  @moduledoc false

  use Application
  alias Zaq.Ingestion.ObanTelemetry

  @impl true
  def start(_type, _args) do
    roles =
      case System.get_env("ROLES") do
        nil ->
          Application.get_env(:zaq, :roles, [:all])

        roles_str ->
          roles_str
          |> String.split(",")
          |> Enum.map(&(&1 |> String.trim() |> String.to_atom()))
      end

    ObanTelemetry.attach()

    children =
      [
        ZaqWeb.Telemetry,
        Zaq.Repo,
        {DNSCluster, query: Application.get_env(:zaq, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Zaq.PubSub},
        {Oban, Application.fetch_env!(:zaq, Oban)},
        Zaq.License.FeatureStore,
        Zaq.License.LicensePostLoader,
        Zaq.Hooks.Supervisor,
        Zaq.PeerConnector
      ]
      |> maybe_add(roles, :engine, Zaq.Engine.Supervisor)
      |> maybe_add(roles, :agent, Zaq.Agent.Supervisor)
      |> maybe_add(roles, :ingestion, Zaq.Ingestion.Supervisor)
      |> maybe_add(roles, :channels, Zaq.Channels.Supervisor)
      |> maybe_add(roles, :bo, ZaqWeb.Endpoint)

    opts = [strategy: :one_for_one, name: Zaq.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ZaqWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # -- Private --

  defp maybe_add(children, roles, role, child) do
    if :all in roles or role in roles do
      children ++ [child]
    else
      children
    end
  end
end

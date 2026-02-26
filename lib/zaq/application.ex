defmodule Zaq.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    roles = Application.get_env(:zaq, :roles, [:all])

    children =
      [
        ZaqWeb.Telemetry,
        Zaq.Repo,
        {DNSCluster, query: Application.get_env(:zaq, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Zaq.PubSub}
      ]
      |> maybe_add(roles, :engine, Zaq.Engine.Supervisor)
      |> maybe_add(roles, :agent, Zaq.Agent.Supervisor)
      |> maybe_add(roles, :ingestion, Zaq.Ingestion.Supervisor)
      |> maybe_add(roles, :channels, Zaq.Channels.Supervisor)
      |> maybe_add(roles, :bo, ZaqWeb.Endpoint)
      |> maybe_add_endpoint(roles)

    opts = [strategy: :one_for_one, name: Zaq.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Always start the endpoint when running all roles,
  # otherwise only start it for :bo or :engine (API)
  defp maybe_add_endpoint(children, roles) do
    if :all in roles do
      children ++ [ZaqWeb.Endpoint]
    else
      children
    end
  end

  defp maybe_add(children, roles, role, child) do
    if :all in roles or role in roles do
      children ++ [child]
    else
      children
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    ZaqWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

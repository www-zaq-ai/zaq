defmodule Zaq.Application do
  @moduledoc false

  use Application
  alias LLMDB.Generated.ValidModalities
  alias Zaq.Agent.ZAQRouter
  alias Zaq.Engine.Workflows
  alias Zaq.Ingestion.FTSBackend
  alias Zaq.Ingestion.ObanTelemetry
  alias Zaq.System.UpdateBadgeWorker

  @impl true
  def start(_type, _args) do
    roles = Zaq.NodeRoles.current()

    ObanTelemetry.attach()

    children =
      [
        ZaqWeb.Telemetry,
        Zaq.Repo,
        {DNSCluster, query: Application.get_env(:zaq, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Zaq.PubSub},
        {Task.Supervisor, name: Zaq.TaskSupervisor},
        {Oban, Application.fetch_env!(:zaq, Oban)},
        Zaq.Addons.FeatureStore,
        Zaq.Addons.PostLoader,
        Zaq.Hooks.Supervisor,
        Zaq.PeerConnector
      ]
      |> maybe_add(roles, :engine, Zaq.Engine.Supervisor)
      |> maybe_add(roles, :agent, Zaq.Agent.Supervisor)
      |> maybe_add(roles, :ingestion, Zaq.Ingestion.Supervisor)
      |> maybe_add(roles, :channels, Zaq.Channels.Supervisor)
      |> maybe_add_web_endpoint(roles)

    children =
      if Application.get_env(:zaq, :e2e_routes, false) do
        children ++ [Zaq.E2E.ProcessorState, Zaq.E2E.PortalState]
      else
        children
      end

    children =
      if Application.get_env(:zaq, :e2e, false) do
        children ++ [Zaq.E2E.LogCollector]
      else
        children
      end

    opts = [strategy: :one_for_one, name: Zaq.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, _pid} = ok ->
        FTSBackend.detect_and_cache()
        enqueue_release_badge_check_on_startup()
        # Forces ValidModalities to load so all modality atoms exist in the VM
        # before LLMDB.load/0 calls String.to_existing_atom/1 on the snapshot.
        _ = ValidModalities.list()
        LLMDB.load(ZAQRouter.llmdb_opts())
        Workflows.load_cron_triggers()
        ok

      other ->
        other
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    ZaqWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  @impl true
  def prep_stop(state) do
    state
  end

  # -- Private --

  defp maybe_add(children, roles, role, child) do
    if :all in roles or role in roles do
      children ++ [child]
    else
      children
    end
  end

  defp maybe_add_web_endpoint(children, roles) do
    if :all in roles or :bo in roles or :channels in roles do
      children ++ [ZaqWeb.Endpoint]
    else
      children
    end
  end

  defp enqueue_release_badge_check_on_startup do
    %{"force" => true}
    |> UpdateBadgeWorker.new()
    |> Oban.insert()
  end
end

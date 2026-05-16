defmodule Zaq.Application do
  @moduledoc false

  use Application
  require Logger
  alias LLMDB.Generated.ValidModalities
  alias Zaq.Ingestion.ObanTelemetry
  alias Zaq.System.UpdateBadgeWorker

  @impl true
  def start(_type, _args) do
    roles = Zaq.NodeRoles.current()

    case ObanTelemetry.attach() do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end

    opts = [strategy: :one_for_one, name: Zaq.Supervisor]

    case Supervisor.start_link(build_children(roles), opts) do
      {:ok, _pid} = ok ->
        on_supervisor_started()
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

  defp build_children(roles) do
    [
      ZaqWeb.Telemetry,
      Zaq.Repo,
      {DNSCluster, query: Application.get_env(:zaq, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Zaq.PubSub},
      {Task.Supervisor, name: Zaq.TaskSupervisor},
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
    |> maybe_add_web_endpoint(roles)
    |> then(fn c ->
      if Application.get_env(:zaq, :e2e_routes, false), do: c ++ [Zaq.E2E.ProcessorState], else: c
    end)
    |> then(fn c ->
      if Application.get_env(:zaq, :e2e, false), do: c ++ [Zaq.E2E.LogCollector], else: c
    end)
  end

  defp on_supervisor_started do
    case enqueue_release_badge_check_on_startup() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue release badge check: #{inspect(reason)}")
    end

    # Forces ValidModalities to load so all modality atoms exist in the VM
    # before LLMDB.load/0 calls String.to_existing_atom/1 on the snapshot.
    case ValidModalities.list() do
      list when is_list(list) -> :ok
    end

    case LLMDB.load() do
      {:ok, _snapshot} ->
        :ok

      {:error, reason} ->
        Logger.warning("LLMDB.load/0 failed at startup: #{inspect(reason)}")
    end
  end

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

defmodule Zaq.TestSupport.PeopleAuthPeer do
  @moduledoc false
  alias Zaq.Channels.PeopleAuthRateLimiter, as: Ingress
  alias Zaq.People.AuthRateLimiter

  def start_application(config, roles) do
    {:ok, _} = Application.ensure_all_started(:logger)
    Logger.configure(level: :warning)
    System.delete_env("ROLES")
    Application.put_all_env([{:zaq, config}])
    Application.put_env(:zaq, :roles, roles)
    Application.put_env(:zaq, :channels, %{})
    Application.put_env(:zaq, :e2e, false)
    Application.put_env(:zaq, :e2e_routes, false)
    Application.put_env(:zaq, :node_router, Zaq.NodeRouter)

    Application.put_env(
      :zaq,
      Zaq.Repo,
      config |> Keyword.fetch!(Zaq.Repo) |> Keyword.put(:pool, DBConnection.ConnectionPool)
    )

    {:ok, _} = Application.ensure_all_started(:zaq)
    refresh(roles)
    :ok
  end

  def start(repo_config, roles \\ [:engine, :channels], opts \\ []) do
    {:ok, _} = Application.ensure_all_started(:logger)
    Logger.configure(level: :warning)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

    Application.put_env(
      :zaq,
      Zaq.Repo,
      Keyword.put(repo_config, :pool, Keyword.get(opts, :pool, DBConnection.ConnectionPool))
    )

    role_children =
      Enum.flat_map(roles, fn
        :engine -> [Zaq.Repo, AuthRateLimiter]
        :channels -> [Ingress]
      end)

    {:ok, root} =
      Supervisor.start_link(
        [
          {Phoenix.PubSub, name: Zaq.PubSub, pool_size: 1}
        ] ++ role_children,
        strategy: :one_for_one
      )

    Process.unlink(root)
    # Real Engine config routing discovers its role by the supervisor's registered
    # name. This minimal peer root supplies that marker without unrelated services.
    if :engine in roles, do: Process.register(root, Zaq.Engine.Supervisor)
    refresh(roles)
    :ok
  end

  def refresh(roles \\ [:channels]) do
    if :channels in roles do
      send(Ingress.Config, :refresh)
      _ = :sys.get_state(Ingress.Config)
    end

    :ok
  end

  def connect(other) do
    {ref, members} = :pg.monitor(Phoenix.PubSub, Zaq.PubSub.Adapter)
    :ok = connect_node(other, 600)
    wait_member(ref, members, other)
    :pg.demonitor(Phoenix.PubSub, ref)
    :ok
  end

  defp connect_node(_other, 0), do: {:error, :peer_connection_failed}

  defp connect_node(other, attempts) do
    if Node.connect(other) do
      :ok
    else
      Process.sleep(100)
      connect_node(other, attempts - 1)
    end
  end

  defp wait_member(ref, members, other) do
    unless Enum.any?(members, &(node(&1) == other)) do
      receive do
        {^ref, :join, _group, joined} -> wait_member(ref, members ++ joined, other)
      after
        5_000 -> raise "peer PubSub membership did not converge"
      end
    end
  end

  def observer do
    caller = self()

    pid =
      spawn(fn ->
        :ok = Phoenix.PubSub.subscribe(Zaq.PubSub, "pr3:rate-barrier")
        send(caller, :subscribed)

        receive do
          :barrier ->
            # The marker follows increments through the same PG2 worker. Its barrier
            # ensures dispatch completed before synchronizing with the rate listener.
            _ = :sys.get_state(Zaq.PubSub.Adapter)

            for listener <- [AuthRateLimiter.Listener, Ingress.Listener],
                Process.whereis(listener),
                do: :sys.get_state(listener)

            receive do
              {:await, from, ref} -> send(from, {ref, :converged})
            end
        end
      end)

    receive do
      :subscribed -> pid
    end
  end

  def record(ip, count) do
    results = for _ <- 1..count, do: Ingress.record_failed_identification(ip)
    :ok = Phoenix.PubSub.broadcast(Zaq.PubSub, "pr3:rate-barrier", :barrier)
    results
  end

  def record_engine_person(person, count) do
    results =
      for _ <- 1..count,
          do: AuthRateLimiter.hit(:engine, {:send_person, person}, 900_000, 5)

    :ok = Phoenix.PubSub.broadcast(Zaq.PubSub, "pr3:rate-barrier", :barrier)
    results
  end

  def await(observer) do
    ref = make_ref()
    send(observer, {:await, self(), ref})

    receive do
      {^ref, :converged} -> :ok
    after
      5_000 -> raise "rate broadcasts did not converge"
    end
  end
end

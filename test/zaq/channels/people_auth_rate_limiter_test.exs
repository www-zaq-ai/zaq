defmodule Zaq.Channels.PeopleAuthRateLimiterTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  alias Zaq.Channels.PeopleAuthRateLimiter, as: Ingress
  alias Zaq.Channels.PeopleAuthRateLimiter.Config
  alias Zaq.People.AuthRateLimiter

  setup do
    refresh()
    unique = System.unique_integer([:positive])
    %{ip: {0, 0, 0, 0, 0, 0, div(unique, 65_536), rem(unique, 65_536)}}
  end

  test "local precheck and failure accounting perform no SQL or Engine dispatch", %{ip: ip} do
    {:ok, _} = Zaq.System.save_people_access_config(%{unknown_email_attempt_limit: 2})
    refresh()
    caller = self()
    id = "ingress-query-#{inspect(make_ref())}"

    :ok =
      :telemetry.attach(
        id,
        [:zaq, :repo, :query],
        fn _, _, _, _ ->
          send(caller, :sql)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
    :ok = Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")
    # Engine issuance infrastructure is independent of the cached ingress precheck.
    assert :ok = Supervisor.terminate_child(Zaq.Engine.Supervisor, AuthRateLimiter)

    try do
      for _ <- 1..5, do: assert(:ok = Ingress.check_identification(ip))
      assert :ok = Ingress.record_failed_identification(ip)
      assert :ok = Ingress.check_identification(ip)
      assert :ok = Ingress.record_failed_identification(ip)
      assert {:error, {:rate_limited, retry}} = Ingress.check_identification(ip)
      assert retry > 0 and retry <= 600_000
      refute_received :sql
      refute_received {:node_router_event, _}
    after
      {:ok, _} = Supervisor.restart_child(Zaq.Engine.Supervisor, AuthRateLimiter)
    end
  end

  test "a missing cache denies and restarting it preserves counters", %{ip: ip} do
    {:ok, _} = Zaq.System.save_people_access_config(%{unknown_email_attempt_limit: 1})
    refresh()
    assert :ok = Ingress.record_failed_identification(ip)
    assert :ok = Supervisor.terminate_child(Ingress, Config)

    try do
      assert {:error, :rate_limiter_unavailable} = Ingress.check_identification(ip)
    after
      {:ok, _} = Supervisor.restart_child(Ingress, Config)
    end

    refresh()
    assert {:error, {:rate_limited, _}} = Ingress.check_identification(ip)
  end

  test "Engine outage during refresh denies immediately and recovery retains quota", %{ip: ip} do
    {:ok, _} = Zaq.System.save_people_access_config(%{unknown_email_attempt_limit: 1})
    refresh()
    assert :ok = Ingress.record_failed_identification(ip)
    engine = Process.whereis(Zaq.Engine.Supervisor)
    Process.unregister(Zaq.Engine.Supervisor)

    try do
      refresh()
      assert {:error, :rate_limiter_unavailable} = Ingress.check_identification(ip)
      assert {:error, :rate_limiter_unavailable} = Ingress.record_failed_identification(ip)
    after
      Process.register(engine, Zaq.Engine.Supervisor)
    end

    refresh()
    assert {:error, {:rate_limited, _}} = Ingress.check_identification(ip)
  end

  test "snapshot reads do not wait for the refresh worker", %{ip: ip} do
    :ok = :sys.suspend(Config)

    try do
      assert :ok = Ingress.check_identification(ip)
      assert :ok = Ingress.record_failed_identification(ip)
    after
      :ok = :sys.resume(Config)
    end
  end

  test "a database-unavailable refresh fails closed without crashing the cache", %{ip: ip} do
    repo = Process.whereis(Zaq.Repo)
    Process.unregister(Zaq.Repo)

    try do
      refresh()
      assert {:error, :rate_limiter_unavailable} = Ingress.check_identification(ip)
    after
      Process.register(repo, Zaq.Repo)
    end

    refresh()
    assert :ok = Ingress.check_identification(ip)
  end

  test "refresh applies limits to current counters and rejects corrupt configuration", %{ip: ip} do
    assert :ok = Ingress.record_failed_identification(ip)
    {:ok, _} = Zaq.System.save_people_access_config(%{unknown_email_attempt_limit: 1})
    assert :ok = Ingress.check_identification(ip)
    refresh()
    assert {:error, {:rate_limited, _}} = Ingress.check_identification(ip)
    {:ok, _} = Zaq.System.save_people_access_config(%{unknown_email_window_seconds: 601})
    refresh()
    assert :ok = Ingress.check_identification(ip)
    {:ok, _} = Zaq.System.set_config("people_access.otp_max_attempts", "bad")
    refresh()
    assert {:error, :rate_limiter_unavailable} = Ingress.check_identification(ip)
    assert {:error, :rate_limiter_unavailable} = Ingress.record_failed_identification(ip)
  end

  test "cold and stale snapshots deny locally", %{ip: ip} do
    :sys.replace_state(Config, fn state ->
      :ets.delete_all_objects(Config)
      state
    end)

    assert {:error, :rate_limiter_unavailable} = Ingress.check_identification(ip)
    refresh()

    :sys.replace_state(Config, fn state ->
      [{:config, config, _}] = :ets.lookup(Config, :config)
      :ets.insert(Config, {:config, config, System.monotonic_time(:millisecond) - 1})
      state
    end)

    assert {:error, :rate_limiter_unavailable} = Ingress.check_identification(ip)
    assert {:error, :rate_limiter_unavailable} = Ingress.record_failed_identification(ip)
  end

  test "role listeners and namespaces are independent", %{ip: ip} do
    {:ok, _} = Zaq.System.save_people_access_config(%{otp_send_person_limit: 1})
    assert :ok = AuthRateLimiter.reserve_challenge(9_876_543, ip)
    assert :ok = Ingress.check_identification(ip)
    assert :ok = Supervisor.terminate_child(Ingress.Runtime, Ingress.Listener)

    try do
      assert {:error, :rate_limiter_unavailable} = Ingress.check_identification(ip)
      assert {:error, {:rate_limited, _}} = AuthRateLimiter.reserve_challenge(9_876_543, ip)
    after
      {:ok, _} = Supervisor.restart_child(Ingress.Runtime, Ingress.Listener)
    end
  end

  property "untrusted address strings never reach counters" do
    check all(ip <- string(:printable), max_runs: 30) do
      assert {:error, :invalid_ip} = Ingress.check_identification(ip)
      assert {:error, :invalid_ip} = Ingress.record_failed_identification(ip)
    end
  end

  defp refresh do
    send(Config, :refresh)
    _ = :sys.get_state(Config)
  end
end

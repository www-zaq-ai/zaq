defmodule Zaq.Engine.Connect.MutationEventConfigTest do
  use ExUnit.Case, async: true

  test "dev and production configs consume credential notifications under every role" do
    # Evaluate real configs in an isolated VM: synthetic production secrets and
    # role overrides never mutate this test VM or the user's environment.
    script = """
    Mix.start()
    for env <- [:dev, :prod], role <- ~w(all engine agent ingestion storage channels bo) do
      System.put_env("ROLES", role)
      base = Config.Reader.read!("config/config.exs", env: env, target: :host)
      runtime = Config.Reader.read!("config/runtime.exs", env: env, target: :host)
      oban = Config.Reader.merge(base, runtime) |> Keyword.fetch!(:zaq) |> Keyword.fetch!(Oban)
      unless oban[:queues][:connect_credential_notifications] == 1,
        do: raise("credential notifications require one consumer on every role")
      unless oban[:queues][:connect_maintenance] == 1,
        do: raise("maintenance needs its own consumed queue on every role")
      schedules = for {Zaq.Oban.DynamicCron, opts} <- oban[:plugins], entry <- opts[:crontab],
        elem(entry, 1) == Zaq.Engine.Connect.SecretReconciliationWorker, do: entry
      unless schedules == [{"*/5 * * * *", Zaq.Engine.Connect.SecretReconciliationWorker}],
        do: raise("exactly one maintenance schedule required")
      if Enum.any?(oban[:plugins] || [], fn plugin ->
        module = if is_tuple(plugin), do: elem(plugin, 0), else: plugin
        module == Oban.Plugins.Pruner
      end), do: raise("notification retention needs explicit pruner policy")
    end
    System.put_env("E2E", "1")
    e2e = Config.Reader.read!("config/config.exs", env: :test, target: :host)
      |> Keyword.fetch!(:zaq) |> Keyword.fetch!(Oban)
    unless e2e[:testing] == :disabled, do: raise("E2E must use real asynchronous queues")
    unless e2e[:queues][:connect_credential_notifications] == 1,
      do: raise("E2E must consume credential notifications")
    IO.puts("runtime queues enabled and unit-test queues deferred")
    """

    {output, status} =
      System.cmd("elixir", ["-e", script],
        env: [
          {"SYSTEM_CONFIG_ENCRYPTION_KEY", String.duplicate("k", 32)},
          {"DATABASE_URL", "ecto://postgres:postgres@localhost/config_check"},
          {"SECRET_KEY_BASE", String.duplicate("s", 64)},
          {"ERL_FLAGS", "+S 2:2"}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "runtime queues enabled and unit-test queues deferred"
  end

  test "test configuration uses manual Oban to prevent precommit dispatch" do
    assert Oban.config().testing == :manual
    refute Keyword.has_key?(Oban.config().queues, :connect_credential_notifications)
  end
end

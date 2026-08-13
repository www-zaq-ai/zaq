defmodule Zaq.ConfigTest do
  use ExUnit.Case, async: true

  defmodule StubConfig do
    def get(:zaq, :channels, _default) do
      %{google_drive: %{bridge: Zaq.ConfigTest.StubBridge}}
    end
  end

  defmodule StubConfigWithOpts do
    def get(:zaq, :channels, _default, opts) do
      Keyword.fetch!(opts, :channels)
    end
  end

  defmodule StubConfigWithoutGet do
  end

  defmodule StubBridge do
  end

  test "get/4 delegates to injected config module" do
    assert Zaq.Config.get(:zaq, :channels, %{}, config: StubConfig) == %{
             google_drive: %{bridge: StubBridge}
           }
  end

  test "get/4 delegates to injected config module with opts when supported" do
    assert Zaq.Config.get(:zaq, :channels, %{},
             config: StubConfigWithOpts,
             channels: %{google_drive: %{bridge: StubBridge}}
           ) == %{google_drive: %{bridge: StubBridge}}
  end

  test "get/4 falls back to application env when injected config is nil" do
    expected = %{source: :application_env}
    Application.put_env(:zaq, :config_nil_test_key, expected)

    on_exit(fn ->
      Application.delete_env(:zaq, :config_nil_test_key)
    end)

    assert Zaq.Config.get(:zaq, :config_nil_test_key, :default, config: nil) == expected
  end

  test "get/4 falls back to application env when injected atom module has no get callback" do
    expected = %{source: :fallback_for_missing_callback}
    Application.put_env(:zaq, :config_missing_callback_test_key, expected)

    on_exit(fn ->
      Application.delete_env(:zaq, :config_missing_callback_test_key)
    end)

    assert Zaq.Config.get(:zaq, :config_missing_callback_test_key, :default,
             config: StubConfigWithoutGet
           ) == expected
  end

  test "get/4 falls back to application env when injected config is not an atom" do
    expected = %{source: :fallback_for_invalid_config}
    Application.put_env(:zaq, :config_invalid_module_test_key, expected)

    on_exit(fn ->
      Application.delete_env(:zaq, :config_invalid_module_test_key)
    end)

    assert Zaq.Config.get(:zaq, :config_invalid_module_test_key, :default,
             config: %{not: :a_module}
           ) == expected
  end

  describe "process-scoped overrides" do
    test "get/4 returns the default when no override is set" do
      assert Zaq.Config.get(:zaq, :pdict_unset_key, :the_default) == :the_default
    end

    test "put_process/3 overrides application env for this process only" do
      Application.put_env(:zaq, :pdict_scoped_key, :from_app_env)
      on_exit(fn -> Application.delete_env(:zaq, :pdict_scoped_key) end)

      Zaq.Config.put_process(:zaq, :pdict_scoped_key, :from_process)
      assert Zaq.Config.get(:zaq, :pdict_scoped_key, :default) == :from_process

      # A process that is not a caller of this one must not see the override.
      agent = start_supervised!({Agent, fn -> nil end})

      assert Agent.get(agent, fn _ -> Zaq.Config.get(:zaq, :pdict_scoped_key, :default) end) ==
               :from_app_env
    end

    test "an override of nil is honoured and not treated as absent" do
      Application.put_env(:zaq, :pdict_nil_key, :from_app_env)
      on_exit(fn -> Application.delete_env(:zaq, :pdict_nil_key) end)

      Zaq.Config.put_process(:zaq, :pdict_nil_key, nil)
      assert Zaq.Config.get(:zaq, :pdict_nil_key, :default) == nil
    end

    test "delete_process/2 restores the underlying value" do
      Application.put_env(:zaq, :pdict_delete_key, :from_app_env)
      on_exit(fn -> Application.delete_env(:zaq, :pdict_delete_key) end)

      Zaq.Config.put_process(:zaq, :pdict_delete_key, :from_process)
      Zaq.Config.delete_process(:zaq, :pdict_delete_key)

      assert Zaq.Config.get(:zaq, :pdict_delete_key, :default) == :from_app_env
    end

    test "overrides resolve through $callers into spawned tasks" do
      Zaq.Config.put_process(:zaq, :pdict_caller_key, :from_parent)

      task = Task.async(fn -> Zaq.Config.get(:zaq, :pdict_caller_key, :default) end)
      assert Task.await(task) == :from_parent
    end

    test "overrides resolve through a nested chain of $callers" do
      Zaq.Config.put_process(:zaq, :pdict_nested_key, :from_root)

      task =
        Task.async(fn ->
          inner = Task.async(fn -> Zaq.Config.get(:zaq, :pdict_nested_key, :default) end)
          Task.await(inner)
        end)

      assert Task.await(task) == :from_root
    end

    test "the nearest caller in the chain wins" do
      Zaq.Config.put_process(:zaq, :pdict_nearest_key, :from_root)

      task =
        Task.async(fn ->
          Zaq.Config.put_process(:zaq, :pdict_nearest_key, :from_middle)
          inner = Task.async(fn -> Zaq.Config.get(:zaq, :pdict_nearest_key, :default) end)
          Task.await(inner)
        end)

      assert Task.await(task) == :from_middle
    end

    test "a dead caller in the chain does not crash resolution" do
      {pid, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      Process.put(:"$callers", [pid])
      on_exit(fn -> Process.delete(:"$callers") end)

      assert Zaq.Config.get(:zaq, :pdict_dead_caller_key, :the_default) == :the_default
    end

    test "a process override takes precedence over an injected config module" do
      Zaq.Config.put_process(:zaq, :channels, :from_process)

      assert Zaq.Config.get(:zaq, :channels, %{}, config: StubConfig) == :from_process
    end
  end
end

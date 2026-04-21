defmodule Mix.Tasks.Hooks.VerifyTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Hooks.Verify

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "hooks_verify_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp write_fixture(dir, filename, content) do
    path = Path.join(dir, filename)
    File.write!(path, content)
    path
  end

  defp with_glob(glob, fun) do
    original = Application.get_env(:zaq, :hooks_verify_glob)
    Application.put_env(:zaq, :hooks_verify_glob, glob)

    try do
      fun.()
    after
      if is_nil(original) do
        Application.delete_env(:zaq, :hooks_verify_glob)
      else
        Application.put_env(:zaq, :hooks_verify_glob, original)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # scan_file/1 — unit tests (no temp dirs needed for basic regex behaviour)
  # ---------------------------------------------------------------------------

  # Scenario 1
  test "scan_file/1 extracts dispatch_sync call on a single line" do
    dir = tmp_dir()

    on_exit(fn -> File.rm_rf!(dir) end)

    path =
      write_fixture(dir, "example.ex", """
      Hooks.dispatch_sync(:retrieval, payload, ctx)
      """)

    assert Verify.scan_file(path) == [{:retrieval, path}]
  end

  # Scenario 2
  test "scan_file/1 extracts dispatch_async call on a single line" do
    dir = tmp_dir()

    on_exit(fn -> File.rm_rf!(dir) end)

    path =
      write_fixture(dir, "example.ex", """
      Hooks.dispatch_async(:pipeline_complete, payload, ctx)
      """)

    assert Verify.scan_file(path) == [{:pipeline_complete, path}]
  end

  # Scenario 3
  test "scan_file/1 extracts multiple calls from the same file" do
    dir = tmp_dir()

    on_exit(fn -> File.rm_rf!(dir) end)

    path =
      write_fixture(dir, "example.ex", """
      Hooks.dispatch_sync(:retrieval, payload, ctx)
      Hooks.dispatch_async(:retrieval_complete, result, ctx)
      """)

    assert Verify.scan_file(path) == [
             {:retrieval, path},
             {:retrieval_complete, path}
           ]
  end

  # Scenario 4 — known limitation documented in moduledoc
  test "scan_file/1 does NOT detect dispatch when the event is passed as a variable" do
    dir = tmp_dir()

    on_exit(fn -> File.rm_rf!(dir) end)

    path =
      write_fixture(dir, "example.ex", """
      event = :retrieval
      Hooks.dispatch_sync(event, payload, ctx)
      """)

    # The regex only matches literal atoms; dynamic event variables are not captured.
    assert Verify.scan_file(path) == []
  end

  # Scenario 5
  test "scan_file/1 returns empty list for files with no dispatch calls" do
    dir = tmp_dir()

    on_exit(fn -> File.rm_rf!(dir) end)

    path = write_fixture(dir, "example.ex", "defmodule Foo, do: :ok\n")

    assert Verify.scan_file(path) == []
  end

  # ---------------------------------------------------------------------------
  # run/1 — integration tests via Application env glob injection
  # ---------------------------------------------------------------------------

  describe "run/1" do
    setup do
      original = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(original) end)
      :ok
    end

    # Scenario 6
    test "succeeds when all dispatched events are documented" do
      dir = tmp_dir()

      on_exit(fn -> File.rm_rf!(dir) end)

      write_fixture(dir, "pipeline.ex", """
      Hooks.dispatch_sync(:retrieval, payload, ctx)
      Hooks.dispatch_async(:retrieval_complete, result, ctx)
      """)

      with_glob("#{dir}/*.ex", fn ->
        assert :ok = Verify.run([])
      end)

      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "hooks.verify passed"
    end

    # Scenario 7
    test "reports a coverage error when an undocumented event is dispatched" do
      dir = tmp_dir()

      on_exit(fn -> File.rm_rf!(dir) end)

      write_fixture(dir, "pipeline.ex", """
      Hooks.dispatch_sync(:totally_undocumented_event_xyz, payload, ctx)
      """)

      with_glob("#{dir}/*.ex", fn ->
        assert_raise Mix.Error, ~r/hooks.verify failed/, fn ->
          Verify.run([])
        end
      end)

      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "totally_undocumented_event_xyz"
    end

    # Scenario 8
    test "reports a uniqueness error when the same event is dispatched from two files" do
      dir = tmp_dir()

      on_exit(fn -> File.rm_rf!(dir) end)

      write_fixture(dir, "module_a.ex", "Hooks.dispatch_sync(:retrieval, p, c)\n")
      write_fixture(dir, "module_b.ex", "Hooks.dispatch_sync(:retrieval, p, c)\n")

      with_glob("#{dir}/*.ex", fn ->
        assert_raise Mix.Error, ~r/hooks.verify failed/, fn ->
          Verify.run([])
        end
      end)

      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "dispatched from multiple modules"
    end

    # Scenario 9 — happy path on the real codebase
    test "passes on the actual lib/ directory (precommit guard)" do
      assert :ok = Verify.run([])

      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "hooks.verify passed"
    end
  end
end

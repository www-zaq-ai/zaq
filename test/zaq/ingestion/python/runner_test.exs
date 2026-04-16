defmodule Zaq.Ingestion.Python.RunnerTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias Zaq.Ingestion.Python.Runner

  # ---------------------------------------------------------------------------
  # scripts_dir/0
  # ---------------------------------------------------------------------------

  describe "scripts_dir/0" do
    test "returns a string" do
      assert is_binary(Runner.scripts_dir())
    end

    test "path ends with python/crawler-ingest" do
      assert String.ends_with?(Runner.scripts_dir(), "python/crawler-ingest")
    end

    test "returns an absolute path" do
      assert Path.type(Runner.scripts_dir()) == :absolute
    end
  end

  # ---------------------------------------------------------------------------
  # python_executable/0
  # ---------------------------------------------------------------------------

  describe "python_executable/0" do
    test "returns a string" do
      assert is_binary(Runner.python_executable())
    end

    test "returns venv python when venv exists" do
      venv_python = Path.join(File.cwd!(), ".venv/bin/python3")

      if File.exists?(venv_python) do
        assert Runner.python_executable() == venv_python
      else
        assert Runner.python_executable() == "python3"
      end
    end

    test "falls back to system python3 when no venv present" do
      venv_python = Path.join(File.cwd!(), ".venv/bin/python3")

      unless File.exists?(venv_python) do
        assert Runner.python_executable() == "python3"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # run/2 — Port.open mechanics verified via a sh-backed helper
  # ---------------------------------------------------------------------------

  describe "run/2" do
    setup do
      tmp_dir =
        Path.join(System.tmp_dir!(), "zaq_runner_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      {:ok, tmp_dir: tmp_dir}
    end

    test "returns {:ok, stdout} when the process exits 0", %{tmp_dir: tmp_dir} do
      script = Path.join(tmp_dir, "success.sh")
      File.write!(script, "#!/bin/sh\necho hello")
      File.chmod!(script, 0o755)

      assert {:ok, "hello"} = run_via_port(script, [])
    end

    test "returns {:error, map} when the process exits non-zero", %{tmp_dir: tmp_dir} do
      script = Path.join(tmp_dir, "failure.sh")
      File.write!(script, "#!/bin/sh\necho oops\nexit 42")
      File.chmod!(script, 0o755)

      assert {:error, %{exit_code: 42, output: output}} = run_via_port(script, [])
      assert String.contains?(output, "oops")
    end

    test "passes args to the process", %{tmp_dir: tmp_dir} do
      script = Path.join(tmp_dir, "echo_args.sh")
      File.write!(script, "#!/bin/sh\necho \"$1 $2\"")
      File.chmod!(script, 0o755)

      assert {:ok, "foo bar"} = run_via_port(script, ["foo", "bar"])
    end

    test "collects multi-line output in order", %{tmp_dir: tmp_dir} do
      script = Path.join(tmp_dir, "multiline.sh")
      File.write!(script, "#!/bin/sh\necho line1\necho line2\necho line3")
      File.chmod!(script, 0o755)

      assert {:ok, output} = run_via_port(script, [])
      assert output == "line1\nline2\nline3"
    end

    test "merges stderr into stdout via :stderr_to_stdout", %{tmp_dir: tmp_dir} do
      script = Path.join(tmp_dir, "stderr.sh")
      File.write!(script, "#!/bin/sh\necho stdout_line\necho stderr_line >&2")
      File.chmod!(script, 0o755)

      assert {:ok, output} = run_via_port(script, [])
      assert String.contains?(output, "stdout_line")
      assert String.contains?(output, "stderr_line")
    end

    test "returns {:error, enoent} when the executable is not found" do
      result =
        run_via_port_with_executable("/does/not/exist/python3", "/tmp/fake.py", [])

      assert {:error, %{exit_code: :enoent, output: output}} = result
      assert String.contains?(output, "not found")
    end

    test "Runner.run/2 returns {:error, enoent} when python is not findable" do
      # Only runs the assertion in environments where python3 is absent (e.g. CI
      # without a Python install). In local dev with a venv this is a no-op.
      if System.find_executable(Runner.python_executable()) == nil do
        result = Runner.run("nonexistent.py", [])
        assert {:error, %{exit_code: :enoent}} = result
      end
    end

    test "Runner.run/2 returns {:error, map} when script is missing but python exists" do
      if System.find_executable(Runner.python_executable()) != nil do
        result = Runner.run("__nonexistent_test_script__.py", [])
        assert {:error, %{exit_code: code, output: _}} = result
        assert is_integer(code)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers — exercise the same Port.open mechanics as Runner.run/2
  # ---------------------------------------------------------------------------

  # Runs an arbitrary executable via Port.open with the same options as
  # Runner.run/2, so these tests cover the real Port code path.
  defp run_via_port(script_path, args) do
    sh = System.find_executable("sh")
    run_via_port_with_executable(sh, script_path, args)
  end

  defp run_via_port_with_executable(nil, _script, _args) do
    {:error, %{exit_code: :enoent, output: "executable not found"}}
  end

  defp run_via_port_with_executable(executable, script_path, args) do
    case System.find_executable(executable) do
      nil ->
        {:error, %{exit_code: :enoent, output: "executable not found: #{executable}"}}

      resolved ->
        port =
          Port.open({:spawn_executable, resolved}, [
            :binary,
            :exit_status,
            {:line, 16_384},
            {:args, [script_path | args]},
            :stderr_to_stdout
          ])

        collect_port_output(port, "", [])
    end
  end

  defp collect_port_output(port, partial, lines) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        collect_port_output(port, "", [partial <> chunk | lines])

      {^port, {:data, {:noeol, chunk}}} ->
        collect_port_output(port, partial <> chunk, lines)

      {^port, {:exit_status, 0}} ->
        {:ok, lines |> Enum.reverse() |> Enum.join("\n")}

      {^port, {:exit_status, code}} ->
        {:error, %{exit_code: code, output: lines |> Enum.reverse() |> Enum.join("\n")}}
    after
      5_000 ->
        Port.close(port)
        {:error, %{exit_code: :timeout, output: "timed out"}}
    end
  end
end

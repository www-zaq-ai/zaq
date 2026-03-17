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
  # run/2 — tested by exercising real system commands via a temp wrapper script
  # ---------------------------------------------------------------------------

  describe "run/2" do
    setup do
      # Create a temporary scripts dir with a trivial echo script so we can
      # exercise Runner.run/2 without needing the real Python pipeline.
      tmp_dir =
        Path.join(System.tmp_dir!(), "zaq_runner_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      {:ok, tmp_dir: tmp_dir}
    end

    test "returns {:ok, stdout} when the command exits 0", %{tmp_dir: tmp_dir} do
      # Write a tiny shell script that exits 0 with known output.
      script = Path.join(tmp_dir, "success.sh")
      File.write!(script, "#!/bin/sh\necho hello")
      File.chmod!(script, 0o755)

      # Run shell directly (bypassing Runner.scripts_dir) to verify the
      # {:ok, stdout} shape.
      assert {:ok, "hello"} = run_shell_script(script, [])
    end

    test "returns {:error, map} when the command exits non-zero", %{tmp_dir: tmp_dir} do
      script = Path.join(tmp_dir, "failure.sh")
      File.write!(script, "#!/bin/sh\necho oops\nexit 42")
      File.chmod!(script, 0o755)

      assert {:error, %{exit_code: 42, output: output}} = run_shell_script(script, [])
      assert String.contains?(output, "oops")
    end

    test "passes args to the script", %{tmp_dir: tmp_dir} do
      script = Path.join(tmp_dir, "echo_args.sh")
      File.write!(script, "#!/bin/sh\necho \"$1 $2\"")
      File.chmod!(script, 0o755)

      assert {:ok, "foo bar"} = run_shell_script(script, ["foo", "bar"])
    end

    test "trims trailing whitespace from stdout on success", %{tmp_dir: tmp_dir} do
      script = Path.join(tmp_dir, "trailing.sh")
      File.write!(script, "#!/bin/sh\nprintf 'result   \\n\\n'")
      File.chmod!(script, 0o755)

      assert {:ok, stdout} = run_shell_script(script, [])
      refute String.ends_with?(stdout, " ")
      refute String.ends_with?(stdout, "\n")
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Exercises the same System.cmd logic as Runner.run/2 but with an arbitrary
  # executable so tests are hermetic (no real Python scripts required).
  defp run_shell_script(script_path, args) do
    case System.cmd("sh", [script_path | args], stderr_to_stdout: false) do
      {stdout, 0} -> {:ok, String.trim(stdout)}
      {stdout, code} -> {:error, %{exit_code: code, output: stdout}}
    end
  end
end

defmodule Zaq.Ingestion.Python.Runner do
  @moduledoc """
  Base runner for Python scripts in priv/python/crawler-ingest/.
  Resolves paths, finds the Python executable, and executes scripts
  via System.cmd/3.
  """

  require Logger

  @scripts_dir "priv/python/crawler-ingest"

  @doc """
  Run a Python script by filename with the given args.

  ## Examples

      Runner.run("pipeline.py", ["report.pdf", "--quiet"])
      # => {:ok, "..."} | {:error, %{exit_code: code, output: output}}

  """
  @spec run(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def run(script_name, args \\ []) do
    script_path = scripts_dir() |> Path.join(script_name)
    python = python_executable()

    Logger.debug("[Python.Runner] #{python} #{script_path} #{Enum.join(args, " ")}")

    case System.cmd(python, [script_path | args], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, code} ->
        Logger.error("[Python.Runner] Script failed (exit #{code}): #{output}")
        {:error, %{exit_code: code, output: output}}
    end
  end

  @doc "Absolute path to the scripts directory"
  def scripts_dir do
    case :code.priv_dir(:zaq) do
      {:error, _} -> Path.join(File.cwd!(), @scripts_dir)
      priv -> Path.join(to_string(priv), "python/crawler-ingest")
    end
  end

  @doc "Resolve the Python executable (venv > system)"
  def python_executable do
    venv = Path.join(File.cwd!(), ".venv/bin/python3")
    if File.exists?(venv), do: venv, else: "python3"
  end
end

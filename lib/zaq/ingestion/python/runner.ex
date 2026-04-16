defmodule Zaq.Ingestion.Python.Runner do
  @moduledoc """
  Base runner for Python scripts in priv/python/crawler-ingest/.
  Resolves paths, finds the Python executable, and streams script
  output line-by-line via Port for real-time logging.
  """

  require Logger

  @scripts_dir "priv/python/crawler-ingest"
  # 30 minutes — image_to_text can be slow for large PDFs
  @timeout_ms 1_800_000

  @doc """
  Run a Python script by filename with the given args.
  Streams stdout/stderr line-by-line to Logger in real time.

  ## Examples

      Runner.run("pipeline.py", ["report.pdf"])
      # => {:ok, output} | {:error, %{exit_code: code, output: output}}

  """
  @spec run(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def run(script_name, args \\ []) do
    script_path = scripts_dir() |> Path.join(script_name)
    python = python_executable()

    Logger.info("[Python.Runner] Starting: #{script_name} #{Enum.join(args, " ")}")

    try do
      port =
        Port.open({:spawn_executable, python}, [
          :binary,
          :exit_status,
          {:line, 16_384},
          {:args, [script_path | args]},
          :stderr_to_stdout
        ])

      collect_output(port, _partial = "", _lines = [])
    rescue
      e in ErlangError ->
        Logger.error("[Python.Runner] Failed to start: #{inspect(e.original)}")
        {:error, %{exit_code: :enoent, output: "could not start python: #{inspect(e.original)}"}}
    end
  end

  defp collect_output(port, partial, lines) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = partial <> chunk
        log_line(line)
        collect_output(port, "", [line | lines])

      {^port, {:data, {:noeol, chunk}}} ->
        collect_output(port, partial <> chunk, lines)

      {^port, {:exit_status, 0}} ->
        output = lines |> Enum.reverse() |> Enum.join("\n")
        Logger.info("[Python.Runner] Finished successfully")
        {:ok, output}

      {^port, {:exit_status, code}} ->
        output = lines |> Enum.reverse() |> Enum.join("\n")
        Logger.error("[Python.Runner] Failed with exit code #{code}")
        {:error, %{exit_code: code, output: output}}
    after
      @timeout_ms ->
        Port.close(port)
        output = lines |> Enum.reverse() |> Enum.join("\n")
        Logger.error("[Python.Runner] Timed out after #{@timeout_ms}ms")
        {:error, %{exit_code: :timeout, output: output}}
    end
  end

  defp log_line("✗" <> _ = line), do: Logger.error("[Python] #{line}")
  defp log_line("⚠" <> _ = line), do: Logger.warning("[Python] #{line}")
  defp log_line(line), do: Logger.info("[Python] #{line}")

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

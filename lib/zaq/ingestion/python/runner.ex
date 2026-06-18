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

  # Prefix the Python scripts use to mark machine-readable progress lines. Lines
  # starting with this token carry a JSON payload and are forwarded to the
  # `:on_progress` callback instead of being logged as ordinary output.
  @progress_sentinel "ZAQ_PROGRESS "

  @doc """
  Run a Python script by filename with the given args.
  Streams stdout/stderr line-by-line to Logger in real time.

  ## Options

    * `:on_progress` - 1-arity function invoked with the decoded JSON map for
      every `ZAQ_PROGRESS` line the script emits. Defaults to a no-op.

  ## Examples

      Runner.run("pipeline.py", ["report.pdf"])
      # => {:ok, output} | {:error, %{exit_code: code, output: output}}

      Runner.run("image_to_text.py", args, on_progress: &handle/1)

  """
  @spec run(String.t(), [String.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(script_name, args \\ [], opts \\ []) do
    script_path = scripts_dir() |> Path.join(script_name)
    python = python_executable()
    on_progress = normalize_on_progress(opts[:on_progress])

    Logger.info("[Python.Runner] Starting: #{script_name} #{Enum.join(args, " ")}")

    case System.find_executable(python) do
      nil ->
        Logger.error("[Python.Runner] Python executable not found: #{python}")
        {:error, %{exit_code: :enoent, output: "python executable not found: #{python}"}}

      resolved ->
        port =
          Port.open({:spawn_executable, resolved}, [
            :binary,
            :exit_status,
            {:line, 16_384},
            {:args, [script_path | args]},
            :stderr_to_stdout
          ])

        collect_output(port, _partial = "", _lines = [], on_progress)
    end
  end

  defp collect_output(port, partial, lines, on_progress) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = partial <> chunk

        case maybe_emit_progress(line, on_progress) do
          :progress ->
            # Progress lines are consumed: kept out of Logger and returned output.
            collect_output(port, "", lines, on_progress)

          :malformed_progress ->
            # A line carried the progress sentinel but failed to decode. We never
            # log its raw contents (it may carry secrets) nor keep it in output.
            Logger.warning("[Python] discarded malformed ZAQ_PROGRESS line")
            collect_output(port, "", lines, on_progress)

          :not_progress ->
            log_line(line)
            collect_output(port, "", [line | lines], on_progress)
        end

      {^port, {:data, {:noeol, chunk}}} ->
        collect_output(port, partial <> chunk, lines, on_progress)

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

  defp normalize_on_progress(fun) when is_function(fun, 1), do: fun
  defp normalize_on_progress(_), do: fn _payload -> :ok end

  # Decodes and forwards a `ZAQ_PROGRESS {json}` line. A line carrying the
  # sentinel but failing to decode to a map is reported as `:malformed_progress`
  # so the caller can drop it without logging its raw contents (it may carry
  # secrets) — see `collect_output/4`.
  defp maybe_emit_progress(@progress_sentinel <> json, on_progress) do
    case Jason.decode(json) do
      {:ok, payload} when is_map(payload) ->
        on_progress.(payload)
        :progress

      _ ->
        :malformed_progress
    end
  end

  defp maybe_emit_progress(_line, _on_progress), do: :not_progress

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

defmodule Zaq.System.Command do
  @moduledoc """
  General-purpose runner for external CLI commands.

  Resolves an executable (a bare name looked up on `PATH`, or an absolute path),
  spawns it via a Port with an explicit **argument list** — never a shell string,
  so command injection is impossible — captures combined stdout+stderr, and
  enforces a timeout.

  This is the shared primitive behind CLI-backed features (e.g.
  `Zaq.Agent.Tools.Web.Browsing`). Callers build the argument list and interpret
  the output; this module owns only the process plumbing.

  ## Return values

      {:ok, output}                               # exit status 0
      {:error, %{exit_code: code, output: out}}   # non-zero exit
      {:error, %{exit_code: :enoent, output: _}}  # executable not found
      {:error, %{exit_code: :timeout, output: _}} # exceeded :timeout_ms

  `output` is the trimmed, combined stdout+stderr.
  """

  require Logger

  @default_timeout_ms 60_000

  @type result :: {:ok, String.t()} | {:error, %{exit_code: term(), output: String.t()}}

  @doc """
  The default hard timeout (ms) applied when a caller passes no `:timeout_ms`.

  Exposed so callers that layer their own timeout logic (e.g.
  `Zaq.Agent.Tools.Web.Browsing`) can share this constant instead of duplicating
  the literal, which would silently drift.
  """
  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms

  @doc """
  Runs `executable` with `args` and returns its combined output.

  ## Options

    * `:timeout_ms` — hard timeout; defaults to #{@default_timeout_ms}ms.
    * `:log_label` — label used in error/timeout log lines; defaults to the
      executable's basename. Arguments are **never** logged (they may carry
      secrets/PII) — a caller that wants to log a command must do so itself.
  """
  @spec run(String.t(), [String.t()], keyword()) :: result()
  def run(executable, args \\ [], opts \\ []) when is_binary(executable) and is_list(args) do
    timeout_ms = opts[:timeout_ms] || @default_timeout_ms
    label = opts[:log_label] || Path.basename(executable)

    case System.find_executable(executable) do
      nil ->
        Logger.error("[Command] executable not found: #{executable}")
        {:error, %{exit_code: :enoent, output: "executable not found: #{executable}"}}

      resolved ->
        port =
          Port.open({:spawn_executable, resolved}, [
            :binary,
            :exit_status,
            :hide,
            {:args, args},
            :stderr_to_stdout
          ])

        collect_output(port, _chunks = [], timeout_ms, label)
    end
  end

  # Accumulate raw output chunks. We deliberately do NOT use the port's
  # `{:line, _}` mode: it silently drops an unterminated final segment at EOF,
  # which would lose command output that does not end in a newline.
  defp collect_output(port, chunks, timeout_ms, label) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, [data | chunks], timeout_ms, label)

      {^port, {:exit_status, 0}} ->
        {:ok, finalize(chunks)}

      {^port, {:exit_status, code}} ->
        Logger.error("[Command] #{label} exited with code #{code}")
        {:error, %{exit_code: code, output: finalize(chunks)}}
    after
      timeout_ms ->
        safe_close(port)
        drain(port)
        Logger.error("[Command] #{label} timed out after #{timeout_ms}ms")
        {:error, %{exit_code: :timeout, output: finalize(chunks)}}
    end
  end

  # Flush any port messages (data / late :exit_status) that arrived around the
  # timeout so they don't linger in the mailbox as process-lifetime garbage.
  defp drain(port) do
    receive do
      {^port, _} -> drain(port)
    after
      0 -> :ok
    end
  end

  defp finalize(chunks) do
    chunks |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim_trailing("\n")
  end

  # Port.close/1 raises if the port already closed (race with :exit_status);
  # swallow that so a timeout cleanup never crashes the caller.
  defp safe_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end

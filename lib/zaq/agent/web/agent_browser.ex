defmodule Zaq.Agent.Web.AgentBrowser do
  @moduledoc """
  Thin, safe bridge to the [`agent-browser`](https://github.com/vercel-labs/agent-browser)
  CLI — a native Rust browser-automation tool built for AI agents.

  This module resolves the `agent-browser` executable, spawns it with an explicit
  argument list (never a shell string, so no command injection is possible), and
  collects its compact text output. It mirrors the `Zaq.Ingestion.Python.Runner`
  Port pattern: `Port.open({:spawn_executable, resolved}, [..., {:args, args}])`.

  Callers pass the fully-built argument list (subcommand + positional args +
  flags). Building and whitelisting the command is the caller's responsibility —
  see `Zaq.Agent.Tools.Web.Browsing`, which is the only intended caller.

  ## Return values

      {:ok, output}                              # exit status 0
      {:error, %{exit_code: code, output: out}}  # non-zero exit
      {:error, %{exit_code: :enoent, output: _}} # binary not found
      {:error, %{exit_code: :timeout, output: _}}# timed out

  ## Configuration

      config :zaq, #{inspect(__MODULE__)},
        binary: "agent-browser",       # or an absolute path; AGENT_BROWSER_BIN env wins
        default_timeout_ms: 60_000

  The Chrome executable used by the daemon is selected out-of-band via the
  `AGENT_BROWSER_EXECUTABLE_PATH` environment variable (set to the system
  Chromium in the container image) — this module does not manage the browser.
  """

  require Logger

  @default_binary "agent-browser"
  @default_timeout_ms 60_000

  @doc """
  Runs the `agent-browser` CLI with `args` (a list of already-built string
  arguments) and returns its combined output.

  ## Options

    * `:timeout_ms` — hard timeout; defaults to the configured
      `:default_timeout_ms` (#{@default_timeout_ms}ms).
  """
  @spec run([String.t()], keyword()) ::
          {:ok, String.t()} | {:error, %{exit_code: term(), output: String.t()}}
  def run(args, opts \\ []) when is_list(args) do
    timeout_ms = opts[:timeout_ms] || default_timeout_ms()

    case System.find_executable(binary()) do
      nil ->
        Logger.error("[AgentBrowser] executable not found: #{binary()}")
        {:error, %{exit_code: :enoent, output: "agent-browser executable not found: #{binary()}"}}

      resolved ->
        # Log only the subcommand — positional args may carry PII/secrets (e.g.
        # `fill` text). See the redaction discipline in Python.Runner.
        Logger.info("[AgentBrowser] #{List.first(args)}")

        port =
          Port.open({:spawn_executable, resolved}, [
            :binary,
            :exit_status,
            :hide,
            {:args, args},
            :stderr_to_stdout
          ])

        collect_output(port, _chunks = [], timeout_ms)
    end
  end

  # Accumulate raw output chunks. We deliberately do NOT use the port's
  # `{:line, _}` mode: it silently drops an unterminated final segment at EOF,
  # which would lose CLI output that does not end in a newline.
  defp collect_output(port, chunks, timeout_ms) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, [data | chunks], timeout_ms)

      {^port, {:exit_status, 0}} ->
        {:ok, finalize(chunks)}

      {^port, {:exit_status, code}} ->
        Logger.error("[AgentBrowser] exited with code #{code}")
        {:error, %{exit_code: code, output: finalize(chunks)}}
    after
      timeout_ms ->
        safe_close(port)
        Logger.error("[AgentBrowser] timed out after #{timeout_ms}ms")
        {:error, %{exit_code: :timeout, output: finalize(chunks)}}
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

  @doc "Resolved `agent-browser` binary: `AGENT_BROWSER_BIN` env > config > default."
  @spec binary() :: String.t()
  def binary do
    System.get_env("AGENT_BROWSER_BIN") || config()[:binary] || @default_binary
  end

  @doc "Configured default timeout in milliseconds."
  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: config()[:default_timeout_ms] || @default_timeout_ms

  defp config, do: Application.get_env(:zaq, __MODULE__, [])
end

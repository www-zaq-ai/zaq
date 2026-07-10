defmodule Zaq.Agent.Tools.Web.Browsing do
  @moduledoc """
  Drives a real browser to accomplish web tasks — navigate a site, read the page,
  find and fill a form, submit it.

  This action is a **thin, safe proxy** over the
  [`agent-browser`](https://github.com/vercel-labs/agent-browser) CLI. Each call
  runs exactly **one** browser command and returns its compact text output; the
  agent's own LLM tool-calling loop drives the sequence:

      open   → navigate to a URL
      snapshot → get the accessibility tree with refs (`@e1`, `@e2`, …)
      fill   → fill an input by ref or CSS selector
      click / press → submit the form

  The `agent-browser` daemon is **stateful** and persists between calls, so a
  multi-step task is a series of separate tool calls sharing one `session`.

  ## Safety

  - Only a fixed **allowlist** of subcommands is permitted (no `eval`, `mcp`,
    `plugin`, or filesystem commands).
  - Every argument (url, selector, text, …) is passed as a **separate process
    argument** — never interpolated into a shell string — so command injection is
    impossible.
  - `allowed_domains` (param or `AGENT_BROWSER_ALLOWED_DOMAINS` env) constrains
    which hosts the browser may reach, for on-prem safety.

  ## Example

      Browsing.run(%{command: "open", url: "https://example.com"}, %{run_id: "r1"})
      Browsing.run(%{command: "snapshot"}, %{run_id: "r1"})
      #=> {:ok, %{command: "snapshot",
      #           output: "- textbox \\"Email\\" [ref=e2]\\n- button \\"Send\\" [ref=e5]"}}
      Browsing.run(%{command: "fill", selector: "@e2", text: "me@acme.com"}, %{run_id: "r1"})
      # A submit button is often below the fold — scroll it in before clicking.
      Browsing.run(%{command: "scrollintoview", selector: "@e5"}, %{run_id: "r1"})
      Browsing.run(%{command: "click", selector: "@e5"}, %{run_id: "r1"})
      # Never trust the click — verify the effect landed.
      Browsing.run(%{command: "url"}, %{run_id: "r1"})
      #=> {:ok, %{command: "url", output: "https://.../formResponse"}}  # submitted
  """

  use Zaq.Engine.Workflows.Action,
    name: "web_browsing",
    description:
      "Drive a real headless browser with full JavaScript/SPA support (Google Forms, React apps). " <>
        "Workflow: `open` a URL; `snapshot` to list interactive elements with refs (`@e1`, `@e2`); " <>
        "`fill`/`type`/`select`/`click` BY REF. Refs come ONLY from the latest snapshot — snapshot " <>
        "before interacting; if fields are missing or disabled, `wait` then snapshot again. Before " <>
        "clicking a button that may be below the fold (Submit usually is), `scrollintoview` it " <>
        "first. CRITICAL: a click reporting success does NOT prove its effect — after submitting, " <>
        "VERIFY with `url` (a submitted Google Form navigates to `.../formResponse`) or `snapshot` " <>
        "(a confirmation page); if still on the form, it did not submit. One command per call; " <>
        "calls in a run share a browser session.",
    schema: [
      command: [
        type: :string,
        required: true,
        doc:
          "Browser command: open, snapshot, wait, text, url, scrollintoview, click, fill, type, select, check, uncheck, press, close."
      ],
      url: [type: :string, required: false, doc: "URL for `open`."],
      selector: [
        type: :string,
        required: false,
        doc: "Element ref from the latest snapshot (e.g. `@e2`) or a CSS selector."
      ],
      text: [type: :string, required: false, doc: "Text for `fill`/`type`."],
      value: [type: :string, required: false, doc: "Option value for `select`."],
      key: [type: :string, required: false, doc: "Key for `press` (e.g. `Enter`, `Tab`)."],
      wait_for: [
        type: :string,
        required: false,
        doc: "For `wait`: a CSS selector to wait for, or a number of milliseconds (e.g. `3000`)."
      ],
      session: [
        type: :string,
        required: false,
        doc: "Isolated browser session id. Defaults to the run/context id."
      ],
      allowed_domains: [
        type: :string,
        required: false,
        doc: "Comma-separated host patterns the browser may reach."
      ],
      timeout_ms: [type: :integer, required: false, doc: "Per-command timeout override."]
    ],
    output_schema: [
      command: [type: :string, required: true, doc: "The command that ran."],
      output: [
        type: :string,
        required: true,
        doc: "Compact CLI output (accessibility tree, etc.)."
      ]
    ]

  require Logger

  alias Zaq.System.Command

  @default_binary "agent-browser"
  @default_timeout_ms 60_000

  # Headroom added to the per-command self-timeout when declaring the react
  # per-tool budget (see `tool_timeout_ms/0`), so a slow command surfaces a
  # graceful error to the LLM instead of the harness aborting the whole run.
  @react_timeout_headroom_ms 30_000

  # Subcommand allowlist → arity spec. Never spawn anything outside this map.
  # Keep in sync with the agent-browser CLI surface (`agent-browser --help`).
  @commands %{
    "open" => [],
    "snapshot" => [],
    "close" => [],
    "url" => [],
    "wait" => [:wait_for],
    "text" => [:selector],
    "scrollintoview" => [:selector],
    "click" => [:selector],
    "check" => [:selector],
    "uncheck" => [:selector],
    "fill" => [:selector, :text],
    "type" => [:selector, :text],
    "select" => [:selector, :value],
    "press" => [:key]
  }

  @impl Jido.Action
  def run(params, context) when is_map(params) do
    command = params |> Map.get(:command) |> to_string()

    with {:ok, required} <- fetch_command(command),
         :ok <- validate_required(command, required, params),
         {:ok, base_args} <- build_command_args(command, params) do
      args = base_args ++ global_flags(params, context)

      # Log only the subcommand — positional args may carry PII/secrets (e.g.
      # `fill` text). The shared runner never logs args.
      Logger.info("[web_browsing] #{command}")

      binary()
      |> Command.run(args,
        timeout_ms: params[:timeout_ms] || default_timeout_ms(),
        log_label: "agent-browser"
      )
      |> handle_response(command)
    end
  end

  defp fetch_command(command) do
    case Map.fetch(@commands, command) do
      {:ok, required} -> {:ok, required}
      :error -> {:error, "unsupported command: #{command}. Allowed: #{allowed_commands()}"}
    end
  end

  defp validate_required(command, required, params) do
    missing = Enum.reject(required, fn field -> present?(Map.get(params, field)) end)

    case missing do
      [] -> :ok
      fields -> {:error, "#{command} requires: #{Enum.map_join(fields, ", ", &to_string/1)}"}
    end
  end

  # Positional args per command. The optional `open` url is appended only when
  # present. `snapshot -i` yields the ref-annotated accessibility tree; `text`
  # maps to the CLI's `get text <selector>`.
  defp build_command_args("snapshot", _params), do: {:ok, ["snapshot", "-i"]}
  defp build_command_args("open", params), do: {:ok, ["open"] ++ optional(params, :url)}
  defp build_command_args("close", _params), do: {:ok, ["close"]}
  defp build_command_args("url", _params), do: {:ok, ["get", "url"]}
  defp build_command_args("wait", params), do: {:ok, ["wait", get(params, :wait_for)]}
  defp build_command_args("text", params), do: {:ok, ["get", "text", get(params, :selector)]}

  defp build_command_args("scrollintoview", params),
    do: {:ok, ["scrollintoview", get(params, :selector)]}

  defp build_command_args("click", params), do: {:ok, ["click", get(params, :selector)]}
  defp build_command_args("check", params), do: {:ok, ["check", get(params, :selector)]}
  defp build_command_args("uncheck", params), do: {:ok, ["uncheck", get(params, :selector)]}

  defp build_command_args("fill", params),
    do: {:ok, ["fill", get(params, :selector), get(params, :text)]}

  defp build_command_args("type", params),
    do: {:ok, ["type", get(params, :selector), get(params, :text)]}

  defp build_command_args("select", params),
    do: {:ok, ["select", get(params, :selector), get(params, :value)]}

  defp build_command_args("press", params), do: {:ok, ["press", get(params, :key)]}

  # Flags appended after the subcommand: session isolation + optional domain allowlist.
  defp global_flags(params, context) do
    ["--session", session(params, context)] ++ domain_flags(params)
  end

  defp session(params, context) do
    params[:session] || context_id(context) || "zaq"
  end

  defp context_id(context) do
    case Map.get(context, :run_id) || Map.get(context, "run_id") do
      id when is_binary(id) and id != "" -> id
      id when is_integer(id) -> to_string(id)
      _ -> nil
    end
  end

  defp domain_flags(params) do
    case params[:allowed_domains] || System.get_env("AGENT_BROWSER_ALLOWED_DOMAINS") do
      domains when is_binary(domains) and domains != "" -> ["--allowed-domains", domains]
      _ -> []
    end
  end

  defp optional(params, field) do
    case get(params, field) do
      value when is_binary(value) and value != "" -> [value]
      _ -> []
    end
  end

  defp get(params, field), do: to_string(Map.get(params, field))

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp allowed_commands, do: @commands |> Map.keys() |> Enum.sort() |> Enum.join(", ")

  @doc """
  Minimum per-tool react execution timeout (ms) an agent needs while this tool is
  enabled.

  Read generically by `Zaq.Agent.Factory` (via an optional `tool_timeout_ms/0`
  convention) so no per-tool knowledge lives in the factory. A browser command
  drives a real Chrome and a cold `open` can exceed jido_ai's 15s default per-tool
  timeout, which would abort the whole run; this is the per-command self-timeout
  plus headroom so the tool instead returns a graceful error the LLM can act on.
  """
  @spec tool_timeout_ms() :: pos_integer()
  def tool_timeout_ms, do: default_timeout_ms() + @react_timeout_headroom_ms

  # Resolved agent-browser binary: AGENT_BROWSER_BIN env (else PATH default).
  defp binary, do: System.get_env("AGENT_BROWSER_BIN") || @default_binary

  # Default per-command timeout from AGENT_BROWSER_TIMEOUT_MS; a missing or
  # malformed value falls back to @default_timeout_ms rather than raising.
  defp default_timeout_ms do
    with value when is_binary(value) <- System.get_env("AGENT_BROWSER_TIMEOUT_MS"),
         {ms, _} <- Integer.parse(value) do
      ms
    else
      _ -> @default_timeout_ms
    end
  end

  defp handle_response({:ok, output}, command), do: {:ok, %{command: command, output: output}}

  defp handle_response({:error, %{exit_code: :enoent, output: output}}, _command),
    do: {:error, "agent-browser not installed: #{output}"}

  defp handle_response({:error, %{exit_code: :timeout}}, command),
    do: {:error, "#{command} timed out"}

  defp handle_response({:error, %{exit_code: code, output: output}}, command),
    do: {:error, "#{command} failed (exit #{code}): #{output}"}
end

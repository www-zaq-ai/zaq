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
      Browsing.run(%{command: "click", selector: "@e5"}, %{run_id: "r1"})
  """

  use Zaq.Engine.Workflows.Action,
    name: "web_browsing",
    description:
      "Drive a browser: navigate a site, snapshot the page for element refs, fill inputs, " <>
        "click/submit. One command per call; steps share a session.",
    schema: [
      command: [
        type: :string,
        required: true,
        doc:
          "Browser command: open, snapshot, read, click, fill, type, select, press, check, close."
      ],
      url: [type: :string, required: false, doc: "URL for `open`/`read`."],
      selector: [
        type: :string,
        required: false,
        doc: "Element ref from a snapshot (e.g. `@e2`) or a CSS selector."
      ],
      text: [type: :string, required: false, doc: "Text for `fill`/`type`."],
      value: [type: :string, required: false, doc: "Option value for `select`."],
      key: [type: :string, required: false, doc: "Key for `press` (e.g. `Enter`, `Tab`)."],
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

  alias Zaq.Agent.Web.AgentBrowser

  # Subcommand allowlist → arity spec. Never spawn anything outside this map.
  @commands %{
    "open" => [],
    "snapshot" => [],
    "read" => [],
    "close" => [],
    "click" => [:selector],
    "check" => [:selector],
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

      args
      |> AgentBrowser.run(timeout_ms: params[:timeout_ms])
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

  # Positional args per command. Optional positionals (open/read url) are appended
  # only when present. `snapshot -i` yields the ref-annotated accessibility tree.
  defp build_command_args("snapshot", _params), do: {:ok, ["snapshot", "-i"]}
  defp build_command_args("open", params), do: {:ok, ["open"] ++ optional(params, :url)}
  defp build_command_args("read", params), do: {:ok, ["read"] ++ optional(params, :url)}
  defp build_command_args("close", _params), do: {:ok, ["close"]}
  defp build_command_args("click", params), do: {:ok, ["click", get(params, :selector)]}
  defp build_command_args("check", params), do: {:ok, ["check", get(params, :selector)]}

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

  defp handle_response({:ok, output}, command), do: {:ok, %{command: command, output: output}}

  defp handle_response({:error, %{exit_code: :enoent, output: output}}, _command),
    do: {:error, "agent-browser not installed: #{output}"}

  defp handle_response({:error, %{exit_code: :timeout}}, command),
    do: {:error, "#{command} timed out"}

  defp handle_response({:error, %{exit_code: code, output: output}}, command),
    do: {:error, "#{command} failed (exit #{code}): #{output}"}
end

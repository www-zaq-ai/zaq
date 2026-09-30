defmodule Zaq.Agent.Tools.Web.Browsing do
  @moduledoc """
  Drives a real browser to accomplish web tasks — navigate a site, read the page,
  find and fill a form, submit it.

  This action is a **thin, safe proxy** over the
  [`agent-browser`](https://github.com/vercel-labs/agent-browser) CLI. Each call
  runs one browser command per call (except `screenshot`, which first reads the
  current URL) and returns compact output; the agent's own LLM tool-calling loop
  drives the sequence:

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
  - Global Web browsing settings define the allowed hosts. An agent cannot
    change the policy by supplying tool arguments or environment variables.

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

  # Subcommand allowlist → arity spec. Never spawn anything outside this map.
  # Keep in sync with the agent-browser CLI surface (`agent-browser --help`).
  @commands %{
    "open" => [],
    "snapshot" => [],
    "close" => [],
    "url" => [],
    "screenshot" => [],
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

  @schema Zoi.object(
            %{
              command:
                Zoi.enum(@commands |> Map.keys() |> Enum.sort(),
                  description: "Allowlisted browser command to execute."
                ),
              url: Zoi.string(description: "URL for open.") |> Zoi.optional(),
              selector:
                Zoi.string(description: "Element ref from the latest snapshot or CSS selector.")
                |> Zoi.optional(),
              text: Zoi.string(description: "Text for fill/type.") |> Zoi.optional(),
              value: Zoi.string(description: "Option value for select.") |> Zoi.optional(),
              key: Zoi.string(description: "Key for press (e.g. Enter, Tab).") |> Zoi.optional(),
              wait_for:
                Zoi.string(description: "CSS selector or millisecond count for wait.")
                |> Zoi.optional(),
              session:
                Zoi.string(
                  description:
                    "Browser session id. Reuse it across calls; if omitted, keep omitting it."
                )
                |> Zoi.optional(),
              timeout_ms:
                Zoi.integer(description: "Positive per-command timeout in milliseconds.")
                |> Zoi.optional()
            },
            unrecognized_keys: :error
          )
          |> Zoi.refine({__MODULE__, :validate_input, []})

  @output_schema Zoi.object(
                   %{
                     command: Zoi.string(description: "The command that ran."),
                     output: Zoi.string(description: "Compact browser output."),
                     record:
                       Zaq.Contracts.Record.zoi_type(
                         description: "Canonical stored screenshot Record, on screenshot success."
                       )
                       |> Zoi.optional()
                   },
                   unrecognized_keys: :error
                 )
                 |> Zoi.refine({__MODULE__, :validate_output, []})

  use Zaq.Engine.Workflows.Action,
    name: "web_browsing",
    description:
      "Drive a real browser, one command per call. Use `open`, then `snapshot` for " <>
        "interactive refs or `text` with selector `body` for readable content. " <>
        "Interact using refs from the latest snapshot; `wait` and snapshot again " <>
        "if content is still loading. Keep the same explicit session for the whole " <>
        "task; if no session was supplied, keep omitting it instead of inventing " <>
        "one later. A successful `open` or `click` does not prove the intended page " <>
        "loaded or a submission worked: check `url` and page text. For an empty or " <>
        "Blocked snapshot, read `text` with selector `body` to diagnose it. " <>
        "The administrator controls allowed domains; do not attempt to override them. " <>
        "Use `screenshot` to store a viewport PNG in the administrator's datasource; " <>
        "if storage fails, no screenshot has been saved.",
    schema: @schema,
    output_schema: @output_schema

  require Logger

  alias Zaq.Agent.Tools.DataSource.CreateDocument
  alias Zaq.Event
  alias Zaq.Events.Helper
  alias Zaq.Events.TrustedContext
  alias Zaq.NodeRouter
  alias Zaq.System.Command
  alias Zaq.System.WebBrowsingConfig

  @default_binary "agent-browser"
  @max_screenshot_bytes 10 * 1024 * 1024
  @png_signature <<137, 80, 78, 71, 13, 10, 26, 10>>

  # Headroom added to the per-command self-timeout when declaring the react
  # per-tool budget (see `tool_timeout_ms/0`), so a slow command surfaces a
  # graceful error to the LLM instead of the harness aborting the whole run.
  @react_timeout_headroom_ms 30_000

  @impl Jido.Action
  def run(params, context) when is_map(params) do
    command = params |> Map.get(:command) |> to_string()

    with {:ok, required} <- fetch_command(command),
         :ok <- validate_required(command, required, params),
         {:ok, base_args} <- build_command_args(command, params),
         {:ok, config} <- configured_config(context) do
      domains = config.allowed_domains
      args = base_args ++ global_flags(params, context, domains)

      # Log only the subcommand — positional args may carry PII/secrets (e.g.
      # `fill` text). The shared runner never logs args.
      Logger.info("[web_browsing] #{command}")

      if command == "screenshot" do
        save_screenshot(params, context, config, domains)
      else
        run_browser(args, params, command)
      end
    end
  end

  @doc "Validates command-specific arguments and the positive timeout for Zoi input parsing."
  def validate_input(%{command: command} = params, _opts) do
    with {:ok, required} <- fetch_command(command),
         :ok <- validate_required(command, required, params) do
      case Map.get(params, :timeout_ms) do
        nil -> :ok
        timeout when is_integer(timeout) and timeout > 0 -> :ok
        _ -> {:error, "timeout_ms must be positive"}
      end
    end
  end

  @doc "Requires a canonical screenshot Record in a successful screenshot result."
  def validate_output(%{command: "screenshot", record: %Zaq.Contracts.Record{}}, _opts),
    do: :ok

  def validate_output(%{command: "screenshot"}, _opts),
    do: {:error, "screenshot result requires a canonical record"}

  def validate_output(_result, _opts), do: :ok

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
  defp build_command_args("screenshot", _params), do: {:ok, ["screenshot"]}
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

  # Always pass a domain flag. Empty is intentional: agent-browser starts its
  # daemon with an empty policy instead of inheriting an old process env value.
  defp global_flags(params, context, domains) do
    ["--session", session(params, context), "--allowed-domains", domains]
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

  defp configured_config(context) do
    request = Event.new(%{}, :engine, opts: [action: :system_config_get_web_browsing_config])
    router = Map.get(context, :node_router, NodeRouter)

    case router.dispatch(request) do
      %Event{response: {:ok, %WebBrowsingConfig{allowed_domains: domains} = config}}
      when is_binary(domains) ->
        {:ok, config}

      _ ->
        {:error, "Web browsing policy unavailable; browser command not executed"}
    end
  end

  defp run_browser(args, params, command) do
    args
    |> run_browser_raw(params)
    |> handle_response(command)
  end

  defp run_browser_raw(args, params) do
    binary()
    |> Command.run(args,
      timeout_ms: params[:timeout_ms] || default_timeout_ms(),
      log_label: "agent-browser"
    )
  end

  defp save_screenshot(params, context, config, domains) do
    with :ok <- validate_destination(config),
         {:ok, %{output: url}} <-
           run_browser(["get", "url"] ++ global_flags(params, context, domains), params, "url"),
         {:ok, host, slug} <- screenshot_page(url),
         {:ok, folder} <- screenshot_folder(config, host, context) do
      path =
        Path.join(
          System.tmp_dir!(),
          "zaq-browser-#{Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)}.png"
        )

      try do
        with :ok <- capture_viewport(path, params, context, domains),
             {:ok, content} <- screenshot_bytes(path),
             {:ok, record} <- upload_screenshot(config, folder, slug, content, context) do
          {:ok, %{command: "screenshot", output: "Screenshot saved", record: record}}
        end
      after
        File.rm(path)
      end
    end
  end

  defp capture_viewport(path, params, context, domains) do
    case run_browser_raw(
           ["screenshot", path] ++ global_flags(params, context, domains),
           params
         ) do
      {:ok, _} ->
        :ok

      {:error, %{exit_code: :timeout}} ->
        {:error, "Screenshot capture timed out"}

      {:error, %{exit_code: :enoent}} ->
        {:error, "Screenshot capture failed: agent-browser not installed"}

      {:error, %{exit_code: code, output: output}} ->
        {:error,
         "Screenshot capture failed (exit #{code}): #{capture_error_detail(output, path)}"}
    end
  end

  defp capture_error_detail(output, path) when is_binary(output) do
    details =
      if String.valid?(output), do: output, else: "agent-browser returned non-text output"

    details =
      details
      |> String.replace(path, "[temporary screenshot]")
      |> String.replace(~r/\x1B\[[0-9;]*m/, "")
      |> String.replace(~r{https?://[^\s"'<>]+}i, "[page URL]")
      |> String.replace(~r{(?:/private)?/(?:tmp|var|Users|home)/[^\s"']+}, "[local path]")
      |> String.replace(
        ~r/\b(?:bearer|token|password|secret|api[_-]?key)[=: ]+[^\s"']+/i,
        "[redacted]"
      )
      |> String.replace(~r/[\x00-\x1f\x7f]+/, " ")
      |> String.slice(0, 240)
      |> String.trim()

    if details == "", do: "agent-browser did not report a reason", else: details
  end

  defp validate_destination(%WebBrowsingConfig{provider: provider, config_id: id} = config)
       when is_binary(provider) and is_integer(id) and id > 0 do
    if config.folder_id || config.folder_path,
      do: :ok,
      else: {:error, "Screenshot destination is not configured"}
  end

  defp validate_destination(_), do: {:error, "Screenshot destination is not configured"}

  defp screenshot_page(url) do
    uri = url |> String.trim() |> URI.parse()

    if uri.scheme in ["http", "https"] and valid_page_host?(uri.host) and
         is_nil(uri.userinfo) do
      host =
        uri.host
        |> String.downcase()
        |> String.replace(":", "-")
        |> String.replace(~r/[^a-z0-9.-]/, "-")
        |> String.slice(0, 253)

      slug =
        (uri.path || "")
        |> URI.decode()
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9]+/, "-")
        |> String.trim("-")
        |> String.slice(0, 80)

      {:ok, host, if(slug == "", do: "home", else: slug)}
    else
      {:error, "Screenshot requires a current HTTP(S) page"}
    end
  rescue
    _ -> {:error, "Screenshot requires a valid HTTP(S) page"}
  end

  defp valid_page_host?(host) when is_binary(host) do
    dns? =
      host
      |> String.split(".")
      |> Enum.all?(fn label ->
        byte_size(label) in 1..63 and
          Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/i, label)
      end)

    ipv6? = String.contains?(host, ":") and Regex.match?(~r/\A[0-9a-f:]+\z/i, host)
    byte_size(host) <= 253 and (dns? or ipv6?)
  end

  defp valid_page_host?(_), do: false

  defp screenshot_bytes(path) do
    with {:ok, %{size: size, type: :regular}} <- File.stat(path),
         true <- size >= byte_size(@png_signature) and size <= @max_screenshot_bytes,
         {:ok, content} <- File.read(path),
         true <- binary_part(content, 0, byte_size(@png_signature)) == @png_signature do
      {:ok, content}
    else
      _ -> {:error, "Screenshot file missing, too large or not a valid PNG"}
    end
  end

  defp screenshot_folder(config, host, context) do
    with {:ok, records} <- list_folders(config, context) do
      case Enum.find(records, &(Map.get(&1, :kind) == :folder and Map.get(&1, :name) == host)) do
        nil -> create_screenshot_folder(config, host, context)
        folder -> {:ok, folder}
      end
    end
  end

  defp list_folders(config, context) do
    parent = config.folder_id || config.folder_path

    request = %{
      provider: config.provider,
      params: %{
        "config_id" => config.config_id,
        "filters" => %{"parent" => parent},
        "include_permissions" => false
      }
    }

    case Helper.build_and_dispatch_invoke_event(
           :channels,
           request,
           :data_source_list_files,
           TrustedContext.event_builder_opts(context)
         ) do
      %Event{response: {:ok, %{records: records, pagination: page}}} when is_list(records) ->
        if Map.get(page || %{}, :has_more?, false) or Map.get(page || %{}, :truncated?, false),
          do: {:error, "Screenshot destination folder listing is incomplete"},
          else: {:ok, records}

      %Event{response: {:ok, %{records: records}}} when is_list(records) ->
        {:ok, records}

      _ ->
        {:error, "Screenshot destination folder could not be listed"}
    end
  end

  defp create_screenshot_folder(config, host, context) do
    case Jido.Exec.run(CreateDocument, folder_params(config, host), context, max_retries: 0) do
      {:ok, %{record: %{id: id} = folder}} when is_binary(id) and id != "" ->
        {:ok, folder}

      _ ->
        # A concurrent writer may have created the same folder. Check once;
        # never retry the create or overwrite an unrelated item.
        with {:ok, records} <- list_folders(config, context),
             %{kind: :folder} = folder <- Enum.find(records, &(Map.get(&1, :name) == host)) do
          {:ok, folder}
        else
          _ -> {:error, "Screenshot destination folder could not be created"}
        end
    end
  end

  defp folder_params(config, name) do
    %{
      provider: config.provider,
      config_id: to_string(config.config_id),
      parent_id: config.folder_id,
      path: config.folder_path,
      name: name,
      kind: "folder"
    }
    |> reject_nil_values()
  end

  defp upload_screenshot(config, folder, slug, content, context) do
    now = DateTime.utc_now()

    timestamp =
      Calendar.strftime(now, "%Y%m%dT%H%M%S") <>
        (now.microsecond
         |> elem(0)
         |> div(1000)
         |> Integer.to_string()
         |> String.pad_leading(3, "0")) <> "Z"

    random = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    name = "#{slug}--#{timestamp}--#{random}.png"

    params =
      %{
        provider: config.provider,
        config_id: to_string(config.config_id),
        parent_id: folder.id,
        path: folder.path,
        name: name,
        content: Base.encode64(content),
        encoding: "base64",
        mime_type: "image/png"
      }
      |> reject_nil_values()

    case Jido.Exec.run(CreateDocument, params, context) do
      {:ok, %{record: %{id: id} = record}} when is_binary(id) and id != "" -> {:ok, record}
      _ -> {:error, "Screenshot could not be saved to the configured destination"}
    end
  end

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

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
  # malformed value falls back to the shared `Command.default_timeout_ms/0`
  # (single source of truth) rather than raising or duplicating the literal.
  defp default_timeout_ms do
    with value when is_binary(value) <- System.get_env("AGENT_BROWSER_TIMEOUT_MS"),
         {ms, _} <- Integer.parse(value) do
      ms
    else
      _ -> Command.default_timeout_ms()
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

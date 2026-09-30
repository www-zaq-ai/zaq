defmodule Zaq.Agent.BrowserFlowIntegrationTest do
  @moduledoc """
  Opt-in real Chromium flow through Executor, Factory, Jido and web_browsing.
  The local website and LLM are doubles; browser execution is never replaced.
  """
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.People
  alias Zaq.Agent.Executor
  alias Zaq.Agent.OpaqueAliases
  alias Zaq.Agent.Tools.DataSource.DeleteDocument
  alias Zaq.Agent.Tools.Web.Browsing
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Storage
  alias Zaq.Storage.{EntryCatalog, VolumeConfig}
  alias Zaq.System.Command
  alias Zaq.TestSupport.{BrowserFlowSite, IntegrationAgent, ToolCallingLLMStub}
  alias Zaq.TestSupport.DiskConfigFixture

  @moduletag :real_browser
  @moduletag timeout: 180_000
  @dummy "Ada Lovelace & QA"

  setup do
    binary = System.get_env("AGENT_BROWSER_BIN") || "agent-browser"
    version = "priv/browser/agent-browser.version" |> File.read!() |> String.trim()
    assert {:ok, output} = Command.run(binary, ["--version"], timeout_ms: 10_000)

    assert String.trim(output) == "agent-browser #{version}",
           "Install the CLI pinned in priv/browser/agent-browser.version; see docs/e2e-testing.md"

    session = "zaq-flow3-#{Ecto.UUID.generate()}"
    # Registered before setup can fail; this closes only our unique session.
    on_exit(fn ->
      assert {:ok, _} = Command.run(binary, ["close", "--session", session], timeout_ms: 15_000)
    end)

    fixture_host = System.get_env("ZAQ_BROWSER_FIXTURE_HOST") || "127.0.0.1"
    bind_ip = if fixture_host == "127.0.0.1", do: {127, 0, 0, 1}, else: {0, 0, 0, 0}

    server =
      start_supervised!(
        {Bandit,
         plug: {BrowserFlowSite, [test_pid: self(), nonce: session]}, ip: bind_ip, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    context = %{
      base: "http://#{fixture_host}:#{port}",
      fixture_host: fixture_host,
      session: session,
      capture_files_before: capture_files()
    }

    assert {:ok, _} = Zaq.System.save_web_browsing_config(%{allowed_domains: fixture_host})
    {:ok, context}
  end

  test "open, follow a link, fill and submit a real browser form", context do
    context = Map.put(context, :agent, configured_agent(context, :form))
    open_presentation(context)

    # Same server and browser session, but a hostname outside the allowlist.
    # Require a policy denial rather than accepting a DNS/connection failure.
    blocked_url = context.base |> URI.parse() |> Map.put(:host, "localhost") |> URI.to_string()
    blocked_params = Map.merge(common(context), %{command: "open", url: blocked_url})

    assert {:error, denial} = Browsing.run(blocked_params, %{})
    assert denial =~ "Domain 'localhost' is not in the allowed domains list"
    refute_received {:browser_page, "/"}

    assert ask(context, "Read the presentation", %{command: "text", selector: "#intro"}) ==
             "A small team building useful software."

    assert ask(context, "Inspect presentation controls", %{command: "snapshot"}) =~
             "Open contact form"

    ask(context, "Follow the contact link", %{command: "click", selector: "#next"})
    ask(context, "Wait for the form", %{command: "wait", wait_for: "#contact-form"})
    assert_received {:browser_page, "/form"}
    assert ask(context, "Check the form address", %{command: "url"}) == context.base <> "/form"

    assert ask(context, "Read the form heading", %{command: "text", selector: "#form-heading"}) ==
             "Contact the team"

    controls = ask(context, "Inspect form controls", %{command: "snapshot"})
    assert controls =~ "Message"
    assert controls =~ "Send message"

    ask(context, "Fill the message with #{@dummy}", %{
      command: "fill",
      selector: "#message",
      text: @dummy
    })

    assert ask(context, "Read the entered message", %{command: "text", selector: "#preview"}) ==
             @dummy

    refute_received {:browser_submission, _}
    ask(context, "Reveal the submit button", %{command: "scrollintoview", selector: "#submit"})
    ask(context, "Submit the form", %{command: "click", selector: "#submit"})
    ask(context, "Wait for confirmation", %{command: "wait", wait_for: "#confirmation"})
    assert_receive {:browser_submission, submitted}, 5_000
    assert submitted == %{"message" => @dummy, "nonce" => context.session}

    assert ask(context, "Read confirmation", %{command: "text", selector: "#confirmation"}) ==
             "Submission received."

    assert ask(context, "Check submission address", %{command: "url"}) ==
             context.base <> "/submit"

    ask(context, "Close the browser", %{command: "close"})
    refute_received {:browser_submission, _}
    refute_received {:llm_stub_error, _}
    refute_received {:llm_tool_call, _, _}
    refute_received {:llm_tool_result, _, _}
    refute_received {:openai_request, _, _, _, _}
  end

  test "agent screenshots upload two real PNGs to the configured Disk folder", context do
    disk = DiskConfigFixture.get_or_create!()
    {:ok, storage_opts} = VolumeConfig.opts_for_channel_config(disk)
    volume = storage_opts |> Keyword.fetch!(:storage_config) |> Keyword.fetch!(:default_volume)
    namespace = "browser-screenshot-#{Ecto.UUID.generate()}"
    {:ok, owned_root} = Storage.resolve_path(volume, namespace, storage_opts)
    File.mkdir_p!(owned_root)
    on_exit(fn -> File.rm_rf!(owned_root) end)

    {:ok, person} = People.create_person(%{full_name: "Screenshot #{namespace}"})
    {:ok, destination} = EntryCatalog.ensure(volume, namespace, "directory")

    assert {:ok, _} =
             Storage.grant_document_access(destination.id, %{
               person_id: person.id,
               access_rights: ["read", "write"]
             })

    assert {:ok, _} =
             Zaq.System.save_web_browsing_config(%{
               allowed_domains: context.fixture_host,
               provider: "disk",
               config_id: disk.id,
               folder_id: destination.id,
               folder_path: "#{volume}/#{namespace}"
             })

    context =
      context
      |> Map.merge(%{
        person: person,
        disk_volume: volume,
        disk_namespace: namespace,
        disk_root: owned_root
      })
      |> Map.put(:agent, configured_agent(context, :screenshot))

    open_presentation(context)

    assert ask(context, "Open the screenshot page", %{
             command: "open",
             url: context.base <> "/form"
           }) =~ "Contact form"

    assert_received {:browser_page, "/form"}

    before_capture = DateTime.utc_now()
    first = ask_result(context, "Capture screenshot one", %{command: "screenshot"})["record"]
    assert_capture(first, context, before_capture)
    first_path = Path.join([owned_root, context.fixture_host, first["name"]])
    first_bytes = File.read!(first_path)
    assert_no_capture_leaks(context)

    second = ask_result(context, "Capture screenshot two", %{command: "screenshot"})["record"]
    assert_capture(second, context, before_capture)
    assert first["id"] != second["id"]
    assert first["name"] != second["name"]
    assert File.read!(first_path) == first_bytes

    assert Enum.sort(File.ls!(Path.join(owned_root, context.fixture_host))) ==
             Enum.sort([first["name"], second["name"]])

    assert_no_capture_leaks(context)
    ask(context, "Close the browser", %{command: "close"})
  end

  defp assert_capture(%{"name" => name} = record, context, before_capture) do
    assert record["kind"] == "file"
    assert record["mime_type"] == "image/png"
    assert is_binary(record["id"])
    relative_path = "#{context.disk_namespace}/#{context.fixture_host}/#{name}"
    assert record["path"] == relative_path

    assert %{id: folder_id, kind: "directory"} =
             EntryCatalog.get_active(
               context.disk_volume,
               "#{context.disk_namespace}/#{context.fixture_host}"
             )

    assert record["parent_id"] == folder_id

    assert %{id: stored_id, kind: "file"} =
             EntryCatalog.get_active(context.disk_volume, relative_path)

    assert record["id"] == stored_id

    assert is_binary(record["provenance_ref"]),
           "browser tool returned no signed provenance; record fields: #{inspect(Map.keys(record))}"

    # The LLM only sees a short prov_ alias; resolve it through the same
    # schema-aware boundary used for subsequent tool calls. No deletion is run.
    assert {:ok, status} = Jido.AgentServer.status(runtime_pid(context.agent, context.session))
    scope = status.raw_state.tool_context.opaque_alias_scope

    assert {:ok, %{arguments: %{"record" => signed}}} =
             OpaqueAliases.expand_tool_call(
               %{action_module: DeleteDocument, arguments: %{"record" => record}},
               %{opaque_alias_scope: scope}
             )

    assert {:ok, _claims} =
             Provenance.verify(%Record{
               id: signed["id"],
               kind: :file,
               name: name,
               parent_id: signed["parent_id"],
               attributes: signed["attributes"] || %{},
               permissions: signed["permissions"],
               provenance_ref: signed["provenance_ref"]
             })

    assert [_, stamp, suffix] =
             Regex.run(~r/^form--(\d{8}T\d{9}Z)--([0-9a-f]{24})\.png$/, name)

    assert byte_size(suffix) == 24

    <<year::binary-size(4), month::binary-size(2), day::binary-size(2), "T", hour::binary-size(2),
      minute::binary-size(2), second::binary-size(2), ms::binary-size(3), "Z">> = stamp

    assert {:ok, captured_at, 0} =
             DateTime.from_iso8601("#{year}-#{month}-#{day}T#{hour}:#{minute}:#{second}.#{ms}Z")

    assert DateTime.compare(captured_at, DateTime.truncate(before_capture, :millisecond)) != :lt
    assert DateTime.compare(captured_at, DateTime.utc_now()) != :gt

    image = File.read!(Path.join([context.disk_root, context.fixture_host, name]))
    assert byte_size(image) > 24

    assert <<137, "PNG\r\n", 26, "\n", _length::32, "IHDR", width::32, height::32, _::binary>> =
             image

    assert width > 0 and height > 0
    assert record["size"] == byte_size(image)
  end

  defp assert_no_capture_leaks(context),
    do: assert(capture_files() == context.capture_files_before)

  defp capture_files, do: Path.wildcard(Path.join(System.tmp_dir!(), "zaq-browser-*.png"))

  defp open_presentation(context) do
    opened = ask(context, "Open the presentation", %{command: "open", url: context.base})
    assert opened =~ "ZAQ browser fixture"
    assert_received {:browser_page, "/"}
  rescue
    error in ExUnit.AssertionError ->
      # Inspect before on_exit closes the only browser session. Do not navigate
      # again: the first real Executor request is also our cold-start diagnostic.
      {:messages, messages} = Process.info(self(), :messages)
      reached_site = {:browser_page, "/"} in messages

      message = """
      #{Exception.message(error)}

      First open of #{context.base} failed.
      BrowserFlowSite GET / notification observed at failure: #{reached_site}
      #{browser_container_diagnostics()}
      """

      reraise %{error | message: message}, __STACKTRACE__
  end

  defp browser_container_diagnostics do
    case System.get_env("ZAQ_BROWSER_CONTAINER") do
      container when is_binary(container) and container != "" ->
        for args <- [
              ["inspect", "--format", "{{json .State}}", container],
              ["top", container, "-eo", "pid,ppid,user,stat,comm"]
            ],
            into: "" do
          result = Command.run("docker", args, timeout_ms: 3_000)

          "docker #{hd(args)} before session cleanup: #{inspect(result, printable_limit: 8_000)}\n"
        end

      _ ->
        "Container diagnostics unavailable: ZAQ_BROWSER_CONTAINER is not set."
    end
  rescue
    error -> "Container diagnostics failed: #{Exception.message(error)}"
  end

  defp ask(context, message, arguments) do
    ask_result(context, message, arguments)["output"]
  end

  defp ask_result(context, message, arguments) do
    incoming = %Incoming{
      content: message,
      channel_id: context.session,
      provider: :web,
      person: context[:person]
    }

    outgoing =
      if context[:person] do
        Executor.run(incoming, agent_id: to_string(context.agent.id), scope: context.session)
      else
        Executor.run(incoming,
          agent_id: to_string(context.agent.id),
          scope: context.session,
          event:
            Zaq.Event.new(incoming, :agent, actor: %{kind: :anonymous, subject: context.session})
        )
      end

    assert outgoing.metadata.error == false,
           "Executor failed for #{arguments.command}: #{inspect(outgoing)}"

    assert_received {:llm_tool_call, "web_browsing", actual_arguments}

    assert actual_arguments ==
             arguments |> Map.merge(common(context)) |> Jason.encode!() |> Jason.decode!()

    assert_received {:llm_tool_result, "web_browsing", result}
    assert result["ok"] == true, inspect(result)
    assert result["result"]["command"] == arguments.command
    assert is_binary(result["result"]["output"])
    assert outgoing.body == "Completed #{arguments.command}."
    pid = runtime_pid(context.agent, context.session)

    assert {:ok, %{status: :completed}} =
             Jido.AgentServer.await_completion(pid,
               status_path: [:__strategy__, :status],
               timeout: 5_000
             )

    for _ <- 1..2 do
      assert_received {:openai_request, "POST", "/v1/responses", _, body}
      assert [%{"name" => "web_browsing"}] = Jason.decode!(body)["tools"]
    end

    result["result"]
  end

  defp configured_agent(context, flow) do
    form_steps = [
      {"Open the presentation", %{command: "open", url: context.base}},
      {"Read the presentation", %{command: "text", selector: "#intro"}},
      {"Inspect presentation controls", %{command: "snapshot"}},
      {"Follow the contact link", %{command: "click", selector: "#next"}},
      {"Wait for the form", %{command: "wait", wait_for: "#contact-form"}},
      {"Check the form address", %{command: "url"}},
      {"Read the form heading", %{command: "text", selector: "#form-heading"}},
      {"Inspect form controls", %{command: "snapshot"}},
      {"Fill the message with #{@dummy}", %{command: "fill", selector: "#message", text: @dummy}},
      {"Read the entered message", %{command: "text", selector: "#preview"}},
      {"Reveal the submit button", %{command: "scrollintoview", selector: "#submit"}},
      {"Submit the form", %{command: "click", selector: "#submit"}},
      {"Wait for confirmation", %{command: "wait", wait_for: "#confirmation"}},
      {"Read confirmation", %{command: "text", selector: "#confirmation"}},
      {"Check submission address", %{command: "url"}},
      {"Close the browser", %{command: "close"}}
    ]

    steps =
      if flow == :screenshot do
        [hd(form_steps)] ++
          [
            {"Open the screenshot page", %{command: "open", url: context.base <> "/form"}},
            {"Capture screenshot one", %{command: "screenshot"}},
            {"Capture screenshot two", %{command: "screenshot"}},
            {"Close the browser", %{command: "close"}}
          ]
      else
        form_steps
      end

    routes =
      Enum.map(steps, fn {message, arguments} ->
        %{
          match: &String.ends_with?(&1, message),
          tool: "web_browsing",
          arguments: fn _ -> Map.merge(arguments, common(context)) end
        }
      end)

    {child, endpoint} =
      ToolCallingLLMStub.server(routes,
        max_interactions: length(steps),
        final_response: fn %{arguments: arguments} -> "Completed #{arguments["command"]}." end
      )

    start_supervised!(child)

    IntegrationAgent.create!(
      endpoint,
      context.session,
      "Use the browser tool to fulfill each request on the provided local site.",
      ["web.browsing"]
    )
  end

  defp common(context),
    do: %{session: context.session, timeout_ms: 30_000}

  defp runtime_pid(agent, session),
    do: Jido.AgentServer.whereis(Jido.registry_name(Zaq.Agent.Jido), "#{agent.name}:#{session}")
end

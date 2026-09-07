defmodule Zaq.Agent.BrowserFlowIntegrationTest do
  @moduledoc """
  Opt-in real Chromium flow through Executor, Factory, Jido and web_browsing.
  The local website and LLM are doubles; browser execution is never replaced.
  """
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.{Executor, ServerManager}
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.System.Command
  alias Zaq.TestSupport.{BrowserFlowSite, ToolCallingLLMStub}

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

    server =
      start_supervised!(
        {Bandit,
         plug: {BrowserFlowSite, [test_pid: self(), nonce: session]}, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    context = %{base: "http://127.0.0.1:#{port}", session: session}
    {:ok, Map.put(context, :agent, configured_agent(context))}
  end

  test "open, follow a link, fill and submit a real browser form", context do
    opened = ask(context, "Open the presentation", %{command: "open", url: context.base})
    assert opened =~ "ZAQ browser fixture"
    assert_received {:browser_page, "/"}

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

  defp ask(context, message, arguments) do
    incoming = %Incoming{content: message, channel_id: context.session, provider: :web}

    outgoing =
      Executor.run(incoming, agent_id: to_string(context.agent.id), scope: context.session)

    assert_received {:llm_tool_call, "web_browsing", actual_arguments}

    assert actual_arguments ==
             arguments |> Map.merge(common(context)) |> Jason.encode!() |> Jason.decode!()

    assert_received {:llm_tool_result, "web_browsing", result}
    assert result["ok"] == true, inspect(result)
    assert result["result"]["command"] == arguments.command
    assert is_binary(result["result"]["output"])
    assert outgoing.metadata.error == false
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

    result["result"]["output"]
  end

  defp configured_agent(context) do
    steps = [
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

    credential =
      ai_credential_fixture(%{
        name: "LLM #{context.session}",
        provider: "openai",
        endpoint: endpoint,
        api_key: "test-key"
      })

    {:ok, agent} =
      Agent.create_agent(%{
        name: "Agent #{context.session}",
        job: "Use the browser tool to fulfill each request on the provided local site.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        active: true,
        enabled_tool_keys: ["web.browsing"],
        conversation_enabled: false,
        model_max_context_tokens: 128_000,
        advanced_options: %{"stream" => false}
      })

    on_exit(fn ->
      case runtime_pid(agent, context.session) do
        nil ->
          :ok

        pid ->
          ref = Process.monitor(pid)
          :ok = ServerManager.stop_server(agent)
          assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
      end
    end)

    agent
  end

  defp common(context),
    do: %{session: context.session, allowed_domains: "127.0.0.1", timeout_ms: 30_000}

  defp runtime_pid(agent, session),
    do: Jido.AgentServer.whereis(Jido.registry_name(Zaq.Agent.Jido), "#{agent.name}:#{session}")
end

defmodule Zaq.Agent.ExecutorIntegrationTest do
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.Executor
  alias Zaq.Agent.ServerManager
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.TestSupport.OpenAIStub

  defmodule StubAgent do
    def get_active_agent(_agent_id), do: {:ok, %{id: 77, name: "Stub Agent"}}
  end

  defmodule StubServerManager do
    def ensure_server(_configured_agent), do: {:ok, :stub_server}
  end

  defmodule StubFactoryResult do
    def ask_with_config(_server, _content, _configured_agent), do: {:ok, :request}
    def await(:request, timeout: 45_000), do: {:ok, %{result: "from-result"}}
  end

  defmodule StubFactoryAnswer do
    def ask_with_config(_server, _content, _configured_agent), do: {:ok, :request}
    def await(:request, timeout: 45_000), do: {:ok, %{answer: "from-answer"}}
  end

  defmodule StubFactoryOther do
    def ask_with_config(_server, _content, _configured_agent), do: {:ok, :request}
    def await(:request, timeout: 45_000), do: {:ok, %{unexpected: 123}}
  end

  test "runs configured agent end-to-end with only AI edge mocked" do
    handler = fn conn, body ->
      payload = Jason.decode!(body)
      assert payload["model"] == "gpt-4.1-mini"

      {200, streamed_reply(conn.request_path, "Yo", "gpt-4.1-mini")}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, self())
    start_supervised!(child_spec)

    credential =
      ai_credential_fixture(%{
        name: "OpenAI Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: endpoint,
        api_key: "test-key"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Executor Integration Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "You are a helper. Reply with Yo.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{"stream" => false}
      })

    on_exit(fn ->
      _ = ServerManager.stop_server(configured_agent.id)
    end)

    incoming = %Incoming{content: "hello", channel_id: "bo-test", provider: :web}

    outgoing = Executor.run(incoming, agent_id: to_string(configured_agent.id))

    assert is_binary(outgoing.body)
    assert outgoing.metadata.error == false
    assert outgoing.metadata.configured_agent_id == configured_agent.id
    assert outgoing.metadata.configured_agent_name == configured_agent.name

    assert_receive {:openai_request, "POST", "/v1/responses", "", _body}, 1_000
  end

  test "runs catalog-only provider via openai runtime fallback" do
    handler = fn conn, body ->
      payload = Jason.decode!(body)
      assert payload["model"] == "deepseek/deepseek-r1-0528"

      {200, streamed_reply(conn.request_path, "Yo", "deepseek/deepseek-r1-0528")}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, self())
    start_supervised!(child_spec)

    credential =
      ai_credential_fixture(%{
        name: "Novita Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "novita_ai",
        endpoint: endpoint,
        api_key: "test-key"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Executor Novita Integration Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "You are a helper. Reply with Yo.",
        model: "deepseek/deepseek-r1-0528",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{"stream" => false}
      })

    on_exit(fn ->
      _ = ServerManager.stop_server(configured_agent.id)
    end)

    incoming = %Incoming{content: "hello", channel_id: "bo-test", provider: :web}

    outgoing = Executor.run(incoming, agent_id: to_string(configured_agent.id))

    assert is_binary(outgoing.body)
    assert outgoing.metadata.error == false
    assert outgoing.metadata.configured_agent_id == configured_agent.id
    assert outgoing.metadata.configured_agent_name == configured_agent.name

    assert_receive {:openai_request, "POST", path, "", _body}, 1_000
    assert path in ["/v1/responses", "/v1/chat/completions"]
  end

  test "sends selected file tools in runtime LLM request" do
    handler = fn conn, body ->
      payload = Jason.decode!(body)

      assert is_list(payload["tools"])

      assert Enum.any?(payload["tools"], fn tool ->
               Map.get(tool, "name") == "read_file" or
                 get_in(tool, ["function", "name"]) == "read_file"
             end)

      {200, streamed_reply(conn.request_path, "Tool configured", "gpt-4.1-mini")}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, self())
    start_supervised!(child_spec)

    credential =
      ai_credential_fixture(%{
        name: "OpenAI Tool Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: endpoint,
        api_key: "test-key"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Executor Tool Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "You can read files when needed.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: ["files.read_file"],
        conversation_enabled: false,
        active: true,
        advanced_options: %{"stream" => false}
      })

    on_exit(fn ->
      _ = ServerManager.stop_server(configured_agent.id)
    end)

    incoming = %Incoming{content: "hello", channel_id: "bo-test", provider: :web}

    outgoing = Executor.run(incoming, agent_id: to_string(configured_agent.id))

    assert is_binary(outgoing.body)
    assert outgoing.metadata.error == false
    assert outgoing.metadata.configured_agent_id == configured_agent.id

    assert_receive {:openai_request, "POST", "/v1/responses", "", _body}, 1_000
  end

  test "executes with updated config after agent update" do
    prompt_v1 = "You are prompt v1. Always answer one."
    prompt_v2 = "You are prompt v2. Always answer two."

    handler = fn conn, _body ->
      {200, streamed_reply(conn.request_path, "ok", "gpt-4.1-mini")}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, self())
    start_supervised!(child_spec)

    credential =
      ai_credential_fixture(%{
        name: "OpenAI Update Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: endpoint,
        api_key: "test-key"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Executor Update Agent #{System.unique_integer([:positive])}",
        description: "",
        job: prompt_v1,
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{"stream" => false}
      })

    on_exit(fn ->
      _ = ServerManager.stop_server(configured_agent.id)
    end)

    incoming = %Incoming{content: "hello", channel_id: "bo-test", provider: :web}

    first_outgoing = Executor.run(incoming, agent_id: to_string(configured_agent.id))
    assert first_outgoing.metadata.error == false

    {:ok, updated_agent} = Agent.update_agent(configured_agent, %{job: prompt_v2})

    second_outgoing = Executor.run(incoming, agent_id: to_string(updated_agent.id))
    assert second_outgoing.metadata.error == false

    assert_receive {:openai_request, "POST", _path1, "", body1}, 1_000
    assert String.contains?(body1, prompt_v1)

    assert_receive {:openai_request, "POST", _path2, "", body2}, 1_000
    assert String.contains?(body2, prompt_v2)
  end

  test "returns graceful error when agent selection is missing" do
    incoming = %Incoming{content: "hello", channel_id: "bo-test", provider: :web}

    outgoing = Executor.run(incoming, [])

    assert outgoing.metadata.error == true
    assert outgoing.metadata.reason == ":missing_agent_selection"
    assert outgoing.body =~ "something went wrong"
  end

  test "returns graceful error when selected agent is inactive" do
    credential =
      ai_credential_fixture(%{
        name: "Inactive Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        api_key: "test-key"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Executor Inactive Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "You are disabled.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: false,
        advanced_options: %{}
      })

    incoming = %Incoming{content: "hello", channel_id: "bo-test", provider: :web}
    outgoing = Executor.run(incoming, agent_id: to_string(configured_agent.id))

    assert outgoing.metadata.error == true
    assert outgoing.metadata.reason == ":inactive_agent"
    assert outgoing.body =~ "something went wrong"
  end

  test "returns graceful error when selected agent does not exist" do
    incoming = %Incoming{content: "hello", channel_id: "bo-test", provider: :web}
    outgoing = Executor.run(incoming, agent_id: "999999999")

    assert outgoing.metadata.error == true
    assert outgoing.metadata.reason == ":agent_not_found"
    assert outgoing.body =~ "something went wrong"
  end

  test "run/1 defaults to missing selection error" do
    incoming = %Incoming{content: "hello", channel_id: "bo-test", provider: :web}
    outgoing = Executor.run(incoming)

    assert outgoing.metadata.error == true
    assert outgoing.metadata.reason == ":missing_agent_selection"
  end

  test "normalizes nested result answer maps" do
    incoming = %Incoming{content: "hello", channel_id: "bo-test", provider: :web}

    outgoing =
      Executor.run(incoming,
        agent_id: "stub",
        agent_module: StubAgent,
        server_manager_module: StubServerManager,
        factory_module: StubFactoryResult
      )

    assert outgoing.body == "from-result"
    assert outgoing.metadata.error == false
  end

  test "normalizes answer key maps" do
    incoming = %Incoming{content: "hello", channel_id: "bo-test", provider: :web}

    outgoing =
      Executor.run(incoming,
        agent_id: "stub",
        agent_module: StubAgent,
        server_manager_module: StubServerManager,
        factory_module: StubFactoryAnswer
      )

    assert outgoing.body == "from-answer"
    assert outgoing.metadata.error == false
  end

  test "falls back to inspect for non-string answers" do
    incoming = %Incoming{content: "hello", channel_id: "bo-test", provider: :web}

    outgoing =
      Executor.run(incoming,
        agent_id: "stub",
        agent_module: StubAgent,
        server_manager_module: StubServerManager,
        factory_module: StubFactoryOther
      )

    assert outgoing.body == "%{unexpected: 123}"
    assert outgoing.metadata.error == false
  end

  test "returns graceful error when provider call fails" do
    handler = fn _conn, _body ->
      {500, %{error: %{message: "upstream failure"}}}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, self())
    start_supervised!(child_spec)

    credential =
      ai_credential_fixture(%{
        name: "OpenAI Failure Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: endpoint,
        api_key: "test-key"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Executor Failure Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "You are a helper.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{"stream" => false}
      })

    on_exit(fn ->
      _ = ServerManager.stop_server(configured_agent.id)
    end)

    incoming = %Incoming{content: "hello", channel_id: "bo-test", provider: :web}
    outgoing = Executor.run(incoming, agent_id: to_string(configured_agent.id))

    assert outgoing.metadata.error == true
    assert outgoing.body =~ "something went wrong"
    assert_receive {:openai_request, "POST", "/v1/responses", "", _body}, 1_000
  end

  defp streamed_reply("/v1/chat/completions", text, model) do
    chunk =
      Jason.encode!(%{
        "id" => "chatcmpl-test",
        "object" => "chat.completion.chunk",
        "model" => model,
        "choices" => [%{"index" => 0, "delta" => %{"content" => text}, "finish_reason" => nil}]
      })

    done_chunk =
      Jason.encode!(%{
        "id" => "chatcmpl-test",
        "object" => "chat.completion.chunk",
        "model" => model,
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 1, "total_tokens" => 6}
      })

    "data: #{chunk}\n\ndata: #{done_chunk}\n\ndata: [DONE]\n\n"
  end

  defp streamed_reply(_path, text, model) do
    delta_event = Jason.encode!(%{"delta" => text})

    completed_event =
      Jason.encode!(%{
        "response" => %{
          "id" => "resp_test",
          "model" => model,
          "usage" => %{"input_tokens" => 5, "output_tokens" => 1, "total_tokens" => 6}
        }
      })

    [
      "event: response.output_text.delta\n",
      "data: #{delta_event}\n\n",
      "event: response.completed\n",
      "data: #{completed_event}\n\n"
    ]
    |> IO.iodata_to_binary()
  end
end

defmodule Zaq.Agent.ExecutorIntegrationTest do
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.Executor
  alias Zaq.Agent.ServerManager
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.TestSupport.OpenAIStub

  test "runs configured agent end-to-end with only AI edge mocked" do
    handler = fn _conn, body ->
      payload = Jason.decode!(body)
      assert payload["model"] == "gpt-4.1-mini"

      {200,
       %{
         "id" => "resp_1",
         "object" => "response",
         "model" => "gpt-4.1-mini",
         "output_text" => "Yo",
         "output" => [],
         "usage" => %{"input_tokens" => 5, "output_tokens" => 1, "total_tokens" => 6}
       }}
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
        advanced_options: %{}
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
    handler = fn _conn, body ->
      payload = Jason.decode!(body)
      assert payload["model"] == "deepseek/deepseek-r1-0528"

      {200,
       %{
         "id" => "resp_2",
         "object" => "response",
         "model" => "deepseek/deepseek-r1-0528",
         "output_text" => "Yo",
         "output" => [],
         "usage" => %{"input_tokens" => 5, "output_tokens" => 1, "total_tokens" => 6}
       }}
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
        advanced_options: %{}
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
    handler = fn _conn, body ->
      payload = Jason.decode!(body)

      assert is_list(payload["tools"])

      assert Enum.any?(payload["tools"], fn tool ->
               Map.get(tool, "name") == "read_file" or
                 get_in(tool, ["function", "name"]) == "read_file"
             end)

      {200,
       %{
         "id" => "resp_3",
         "object" => "response",
         "model" => "gpt-4.1-mini",
         "output_text" => "Tool configured",
         "output" => [],
         "usage" => %{"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}
       }}
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
        advanced_options: %{}
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
end

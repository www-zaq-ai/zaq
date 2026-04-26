defmodule Zaq.Agent.FactoryTest do
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.Answering
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.Factory
  alias Zaq.Agent.ServerManager
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.TestSupport.OpenAIStub

  describe "answering_configured_agent/0" do
    test "returns a ConfiguredAgent with name answering" do
      agent = Answering.answering_configured_agent()
      assert %ConfiguredAgent{} = agent
      assert agent.id == :answering
      assert agent.name == "answering"
    end

    test "includes answering tool keys" do
      agent = Answering.answering_configured_agent()
      assert "answering.search_knowledge_base" in agent.enabled_tool_keys
      assert "answering.ask_for_clarification" in agent.enabled_tool_keys
    end

    test "is active and not conversation-enabled" do
      agent = Answering.answering_configured_agent()
      assert agent.active == true
      assert agent.conversation_enabled == false
    end
  end

  test "strategy_opts does not include model option" do
    refute Keyword.has_key?(Factory.strategy_opts(), :model)
  end

  describe "build_model_spec/0" do
    setup do
      seed_llm_config(%{
        endpoint: "https://api.example.com/v1",
        model: "test-model",
        temperature: 0.1,
        top_p: 0.8
      })

      :ok
    end

    test "returns model spec with provider, id, and base_url" do
      spec = Factory.build_model_spec()

      assert spec.provider == :openai
      assert spec.id == "test-model"
      assert spec.base_url == "https://api.example.com/v1"
    end

    test "generation_opts returns temperature and top_p" do
      opts = Factory.generation_opts()

      assert opts[:temperature] == 0.1
      assert opts[:top_p] == 0.8
    end
  end

  test "ask_with_config returns unknown tools error before runtime call" do
    configured_agent = %Agent.ConfiguredAgent{enabled_tool_keys: ["files.missing"]}

    assert {:error, {:unknown_tools, ["files.missing"]}} =
             Factory.ask_with_config(:unused_server, "hello", configured_agent)
  end

  test "runtime_config returns unknown tools error for invalid selection" do
    configured_agent = %Agent.ConfiguredAgent{enabled_tool_keys: ["files.missing"]}

    assert {:error, {:unknown_tools, ["files.missing"]}} =
             Factory.runtime_config(configured_agent)
  end

  test "ask_with_config builds llm opts across option-key and credential branches" do
    credential =
      ai_credential_fixture(%{
        name: "Factory Branch Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        api_key: nil
      })

    configured_agent = %Agent.ConfiguredAgent{
      job: "job",
      model: "gpt-4.1-mini",
      credential_id: credential.id,
      credential: nil,
      enabled_tool_keys: [],
      advanced_options: %{123 => "ignored", "non_existing" => true, temperature: 0.11}
    }

    assert {:error, _reason} = Factory.ask_with_config(:invalid_server, "hello", configured_agent)
  end

  test "ask_with_config handles nil credential and non-map advanced options" do
    configured_agent = %Agent.ConfiguredAgent{
      job: "job",
      model: "gpt-4.1-mini",
      credential: nil,
      enabled_tool_keys: [],
      advanced_options: "not_a_map"
    }

    assert {:error, _reason} = Factory.ask_with_config(:invalid_server, "hello", configured_agent)
  end

  test "ask_with_config executes end-to-end with server runtime config" do
    handler = fn conn, body ->
      payload = Jason.decode!(body)

      assert payload["model"] == "gpt-4.1-mini"

      {200, streamed_reply(conn.request_path, "Factory reply", "gpt-4.1-mini")}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, self())
    start_supervised!(child_spec)

    credential =
      ai_credential_fixture(%{
        name: "Factory Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: endpoint,
        api_key: "factory-key"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Factory Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "You are a helper",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{"temperature" => 0.33, "this_option_does_not_exist" => true}
      })

    on_exit(fn ->
      _ = ServerManager.stop_server(configured_agent.id)
    end)

    incoming = %Incoming{content: "hello", channel_id: "bo-test", provider: :web}

    assert {:ok, server} = ServerManager.ensure_server(configured_agent)

    assert {:ok, status} = Jido.AgentServer.status(server)
    assert status.raw_state.runtime_config.system_prompt == configured_agent.job
    assert is_list(status.raw_state.runtime_config.llm_opts)

    assert {:ok, request} =
             Factory.ask_with_config(server, incoming.content, configured_agent, timeout: 35_000)

    assert {:ok, answer} = Factory.await(request, timeout: 45_000)
    assert is_binary(answer)

    assert_receive {:openai_request, "POST", "/v1/responses", "", body}, 1_000
    assert body =~ "gpt-4.1-mini"
    assert body =~ configured_agent.job
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

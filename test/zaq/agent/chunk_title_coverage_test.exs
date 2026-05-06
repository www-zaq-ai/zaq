defmodule Zaq.Agent.ChunkTitleCoverageTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.ChunkTitle
  alias Zaq.TestSupport.OpenAIStub

  describe "ask/2 — whitespace-only response" do
    test "returns error when LLM returns only whitespace" do
      handler = fn _conn, _body ->
        {200, OpenAIStub.chat_completion("   ")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      assert {:error, message} = ChunkTitle.ask("Some chunk content")
      assert String.starts_with?(message, "Failed to generate title:")
    end

    test "returns error when LLM returns nil content" do
      handler = fn _conn, _body ->
        {200, OpenAIStub.chat_completion(nil)}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      assert {:error, message} = ChunkTitle.ask("Some chunk content")
      assert String.starts_with?(message, "Failed to generate title:")
    end
  end

  describe "ask/2 — prefix removal variants" do
    test "removes 'Here is' prefix" do
      handler = fn _conn, _body ->
        {200, OpenAIStub.chat_completion("Here is Northwind Industries Overview")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      assert {:ok, "Northwind Industries Overview"} = ChunkTitle.ask("Some chunk content")
    end

    test "removes 'Here's' prefix" do
      handler = fn _conn, _body ->
        {200, OpenAIStub.chat_completion("Here's Policy Details")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      assert {:ok, "Policy Details"} = ChunkTitle.ask("Some chunk content")
    end

    test "removes 'The title is' prefix" do
      handler = fn _conn, _body ->
        {200, OpenAIStub.chat_completion("The title is: Benefits Policy Overview")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      assert {:ok, "Benefits Policy Overview"} = ChunkTitle.ask("Some chunk content")
    end
  end

  describe "ask/2 — LLM error path" do
    test "returns error when LLM returns non-200 status" do
      handler = fn _conn, _body ->
        {500, %{"error" => %{"message" => "Internal server error", "type" => "server_error"}}}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      assert {:error, message} = ChunkTitle.ask("Some chunk content")
      assert String.starts_with?(message, "Failed to generate title:")
    end
  end
end

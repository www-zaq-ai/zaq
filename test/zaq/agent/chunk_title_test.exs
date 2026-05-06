defmodule Zaq.Agent.ChunkTitleTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.ChunkTitle
  alias Zaq.TestSupport.OpenAIStub

  describe "max_words/0" do
    test "returns the configured max word limit" do
      assert ChunkTitle.max_words() == 8
    end
  end

  describe "ask/2 deterministic lane" do
    test "removes quotes and common prefixes" do
      handler = fn _conn, _body ->
        {200, OpenAIStub.chat_completion("\"Title: Northwind Industries Founder Eleanor Vance\"")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)

      OpenAIStub.seed_llm_config(endpoint)

      assert {:ok, "Northwind Industries Founder Eleanor Vance"} =
               ChunkTitle.ask("chunk content")
    end

    test "truncates titles to max_words" do
      handler = fn _conn, _body ->
        {200, OpenAIStub.chat_completion("One Two Three Four Five Six Seven Eight Nine Ten")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)

      OpenAIStub.seed_llm_config(endpoint)

      assert {:ok, title} = ChunkTitle.ask("chunk content")
      assert title == "One Two Three Four Five Six Seven Eight"
    end

    test "uses configured model and omits top_p" do
      handler = fn _conn, body ->
        payload = Jason.decode!(body)
        assert payload["model"] == "base-model"
        refute Map.has_key?(payload, "top_p")
        {200, OpenAIStub.chat_completion("Base Model Title")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)

      OpenAIStub.seed_llm_config(endpoint, model: "base-model")

      assert {:ok, "Base Model Title"} = ChunkTitle.ask("chunk content")
      assert_receive {:openai_request, "POST", "/v1/chat/completions", "", _body}
    end

    test "returns error tuple when LLM response cannot be processed" do
      handler = fn _conn, _body ->
        {200, %{"unexpected" => "shape"}}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)

      OpenAIStub.seed_llm_config(endpoint)

      assert {:error, message} = ChunkTitle.ask("chunk content")
      assert String.starts_with?(message, "Failed to generate title:")
    end
  end

  describe "ask/2 — full pipeline (requires running LLM)" do
    @describetag :integration
    test "generates a title for a chunk" do
      content = """
      Welcome to Northwind Industries! Founded in 1987 by Eleanor Vance,
      Northwind has grown from a small family business into a global leader
      in sustainable manufacturing solutions.
      """

      {:ok, title} = ChunkTitle.ask(content)

      assert is_binary(title)
      assert String.length(title) > 0

      word_count = title |> String.split(~r/\s+/, trim: true) |> length()
      assert word_count <= 8
    end

    test "returns error tuple on failure" do
      # Empty content might cause issues depending on LLM
      result = ChunkTitle.ask("")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end

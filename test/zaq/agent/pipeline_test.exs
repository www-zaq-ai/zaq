defmodule Zaq.Agent.PipelineTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.Answering.Result
  alias Zaq.Agent.Pipeline

  # ---------------------------------------------------------------------------
  # Stubs — injected via opts; no DB or LLM required
  # ---------------------------------------------------------------------------

  defmodule StubNodeRouter do
    def call(_role, module, function, args), do: apply(module, function, args)
  end

  defmodule StubPromptGuard do
    def validate(question), do: {:ok, question}
    def output_safe?(answer), do: {:ok, answer}
  end

  defmodule StubPromptTemplate do
    def render(_slug, _assigns), do: "system prompt"
  end

  # Forwards all dispatch_after events to the registered test process.
  defmodule StubHooks do
    def dispatch_before(_event, payload, _ctx), do: {:ok, payload}

    def dispatch_after(event, payload, _ctx) do
      send(:pipeline_test_pid, {event, payload})
      :ok
    end
  end

  defmodule StubRetrieval do
    def ask(_question, _opts) do
      {:ok,
       %{
         "query" => "test query",
         "language" => "en",
         "positive_answer" => "positive answer",
         "negative_answer" => "negative answer"
       }}
    end
  end

  # Simulates retrieval returning no query — triggers the no_results else branch
  # before do_query_extraction is ever called.
  defmodule StubNoResultsRetrieval do
    def ask(_question, _opts), do: {:ok, %{"negative_answer" => "no info found"}}
  end

  @stub_chunks [
    %{
      "content" => "chunk content",
      "source" => "doc.md",
      "metadata" => %{"origin" => "knowledge_gap", "gap_id" => "abc123"}
    }
  ]

  defmodule StubDocumentProcessor do
    @chunks [
      %{
        "content" => "chunk content",
        "source" => "doc.md",
        "metadata" => %{"origin" => "knowledge_gap", "gap_id" => "abc123"}
      }
    ]

    def query_extraction(_query, _role_ids), do: {:ok, @chunks}
  end

  # Triggers the {:error, :no_results, negative_answer} branch inside
  # do_query_extraction, which dispatches after_pipeline_complete with chunks: [].
  defmodule StubEmptyDocumentProcessor do
    def query_extraction(_query, _role_ids), do: {:ok, []}
  end

  defmodule StubAnswering do
    def ask(_prompt, _opts) do
      {:ok,
       %Result{
         answer: "The answer is 42.",
         confidence_score: 0.9,
         latency_ms: 100,
         prompt_tokens: 10,
         completion_tokens: 5,
         total_tokens: 15
       }}
    end

    def normalize_result(%Result{} = result), do: {:ok, result}
    def no_answer?(_answer), do: false
    def clean_answer(answer), do: answer
  end

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  @base_opts [
    hooks: StubHooks,
    node_router: StubNodeRouter,
    prompt_guard: StubPromptGuard,
    prompt_template: StubPromptTemplate,
    retrieval: StubRetrieval,
    document_processor: StubDocumentProcessor,
    answering: StubAnswering
  ]

  setup do
    # Registered name is auto-unregistered when the test process exits,
    # so no explicit cleanup is needed.
    Process.register(self(), :pipeline_test_pid)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe ":after_pipeline_complete chunks in hook payload" do
    test "includes retrieved chunks on a successful run" do
      Pipeline.run("What is the answer?", @base_opts)

      assert_receive {:after_pipeline_complete, payload}, 1000
      assert payload.chunks == @stub_chunks
    end

    test "chunk entries carry content, source, and metadata" do
      Pipeline.run("What is the answer?", @base_opts)

      assert_receive {:after_pipeline_complete, %{chunks: [chunk]}}, 1000
      assert chunk["content"] == "chunk content"
      assert chunk["source"] == "doc.md"
      assert chunk["metadata"] == %{"origin" => "knowledge_gap", "gap_id" => "abc123"}
    end

    test "chunks is [] when document processor returns no results" do
      opts = Keyword.put(@base_opts, :document_processor, StubEmptyDocumentProcessor)

      Pipeline.run("What is the answer?", opts)

      assert_receive {:after_pipeline_complete, payload}, 1000
      assert payload.chunks == []
    end

    test "chunks is [] when retrieval finds no matching documents" do
      opts = Keyword.put(@base_opts, :retrieval, StubNoResultsRetrieval)

      Pipeline.run("What is the answer?", opts)

      assert_receive {:after_pipeline_complete, payload}, 1000
      assert payload.chunks == []
    end
  end
end

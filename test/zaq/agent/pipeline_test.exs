defmodule Zaq.Agent.PipelineTest do
  use Zaq.DataCase, async: false

  import Ecto.Query

  alias Zaq.Agent.Answering.Result
  alias Zaq.Agent.Pipeline
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Engine.Telemetry.Buffer
  alias Zaq.Engine.Telemetry.Point
  alias Zaq.Repo

  alias Ecto.Adapters.SQL.Sandbox

  # ---------------------------------------------------------------------------
  # Stubs — injected via opts; no DB or LLM required
  # ---------------------------------------------------------------------------

  defmodule StubNodeRouter do
    def call(:channels, Zaq.Channels.Router, :send_typing, [provider, channel_id]) do
      send(:pipeline_test_pid, {:typing_called, provider, channel_id})
      Process.get(:typing_router_result, :ok)
    end

    def call(_role, module, function, args), do: apply(module, function, args)
  end

  defmodule StubIdentityPlug do
    def call(incoming, _opts), do: incoming
  end

  defmodule SpyIdentityPlug do
    def call(incoming, _opts) do
      send(:pipeline_test_pid, :identity_called)
      incoming
    end
  end

  defmodule StubPromptGuard do
    def validate(content), do: {:ok, content}
    def output_safe?(answer), do: {:ok, answer}
  end

  defmodule StubPromptTemplate do
    def render(_slug, _assigns), do: "system prompt"
  end

  # Forwards all dispatch_async events to the registered test process.
  defmodule StubHooks do
    def dispatch_sync(_event, payload, _ctx), do: {:ok, payload}

    def dispatch_async(event, payload, _ctx) do
      send(:pipeline_test_pid, {event, payload})
      :ok
    end
  end

  defmodule StubRetrieval do
    def ask(_content, _opts) do
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
    def ask(_content, _opts), do: {:ok, %{"negative_answer" => "no info found"}}
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
  # do_query_extraction, which dispatches pipeline_complete with chunks: [].
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
    identity_plug: StubIdentityPlug,
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
    Process.delete(:typing_router_result)

    if pid = Process.whereis(Buffer) do
      Sandbox.allow(Repo, self(), pid)
      Buffer.flush()
    end

    Repo.delete_all(Point)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  @incoming %Incoming{content: "What is the answer?", channel_id: "test", provider: :test}

  describe ":pipeline_complete chunks in hook payload" do
    test "includes retrieved chunks on a successful run" do
      Pipeline.run(@incoming, @base_opts)

      assert_receive {:pipeline_complete, payload}, 1000
      assert payload.chunks == @stub_chunks
    end

    test "chunk entries carry content, source, and metadata" do
      Pipeline.run(@incoming, @base_opts)

      assert_receive {:pipeline_complete, %{chunks: [chunk]}}, 1000
      assert chunk["content"] == "chunk content"
      assert chunk["source"] == "doc.md"
      assert chunk["metadata"] == %{"origin" => "knowledge_gap", "gap_id" => "abc123"}
    end

    test "chunks is [] when document processor returns no results" do
      opts = Keyword.put(@base_opts, :document_processor, StubEmptyDocumentProcessor)

      Pipeline.run(@incoming, opts)

      assert_receive {:pipeline_complete, payload}, 1000
      assert payload.chunks == []
    end

    test "chunks is [] when retrieval finds no matching documents" do
      opts = Keyword.put(@base_opts, :retrieval, StubNoResultsRetrieval)

      Pipeline.run(@incoming, opts)

      assert_receive {:pipeline_complete, payload}, 1000
      assert payload.chunks == []
    end
  end

  describe "run/2 team_ids lookup from People" do
    test "completes without error when person_id is nil (no person lookup)" do
      # incoming with nil person_id — should not crash
      incoming = %Incoming{
        content: "What is the answer?",
        channel_id: "ch",
        provider: :test,
        person_id: nil
      }

      Pipeline.run(incoming, @base_opts)
      assert_receive {:pipeline_complete, _}, 1000
    end

    test "run/2 with skip_permissions opt propagates without crashing" do
      opts = Keyword.put(@base_opts, :skip_permissions, true)
      result = Pipeline.run(@incoming, opts)
      assert %Outgoing{} = result
    end
  end

  describe "run/2 return type" do
    test "returns %Outgoing{} with body from pipeline answer" do
      result = Pipeline.run(@incoming, @base_opts)

      assert %Outgoing{} = result
      assert result.body == "The answer is 42."
      assert result.channel_id == "test"
      assert result.provider == :test
    end

    test "outgoing metadata carries pipeline result fields" do
      result = Pipeline.run(@incoming, @base_opts)

      assert result.metadata.answer == "The answer is 42."
      assert result.metadata.confidence_score == 0.9
      assert result.metadata.error == false
    end
  end

  describe "run/2 typing dispatch" do
    test "dispatches typing via router before continuing" do
      result =
        Pipeline.run(
          @incoming,
          Keyword.put(@base_opts, :identity_plug, SpyIdentityPlug)
        )

      assert_receive {:typing_called, :test, "test"}, 1000
      assert_receive :identity_called, 1000
      assert %Outgoing{} = result
      assert result.metadata.error == false
    end

    test "ignores unsupported typing error and still returns successful outgoing" do
      Process.put(:typing_router_result, {:error, :unsupported})

      result = Pipeline.run(@incoming, @base_opts)

      assert_receive {:typing_called, :test, "test"}, 1000
      assert %Outgoing{} = result
      assert result.body == "The answer is 42."
      assert result.metadata.error == false
    end

    test "ignores channel config typing error and still returns successful outgoing" do
      Process.put(:typing_router_result, {:error, {:channel_not_configured, :test}})

      result = Pipeline.run(@incoming, @base_opts)

      assert_receive {:typing_called, :test, "test"}, 1000
      assert %Outgoing{} = result
      assert result.body == "The answer is 42."
      assert result.metadata.error == false
    end

    test "ignores generic typing error and still returns successful outgoing" do
      Process.put(:typing_router_result, {:error, :timeout})

      result = Pipeline.run(@incoming, @base_opts)

      assert_receive {:typing_called, :test, "test"}, 1000
      assert %Outgoing{} = result
      assert result.body == "The answer is 42."
      assert result.metadata.error == false
    end
  end

  describe "run/2 telemetry" do
    test "records message telemetry for successful answers" do
      _result = Pipeline.run(@incoming, @base_opts)

      assert :ok = Buffer.flush()

      assert Repo.aggregate(
               from(p in Point, where: p.metric_key == "qa.message.count"),
               :sum,
               :value
             ) ==
               1.0

      assert Repo.aggregate(
               from(p in Point, where: p.metric_key == "qa.no_answer.count"),
               :sum,
               :value
             ) in [nil, 0.0]
    end

    test "records message and no-answer telemetry in no-results path" do
      opts = Keyword.put(@base_opts, :retrieval, StubNoResultsRetrieval)

      _result = Pipeline.run(@incoming, opts)

      assert :ok = Buffer.flush()

      assert Repo.aggregate(
               from(p in Point, where: p.metric_key == "qa.message.count"),
               :sum,
               :value
             ) ==
               1.0

      assert Repo.aggregate(
               from(p in Point, where: p.metric_key == "qa.no_answer.count"),
               :sum,
               :value
             ) == 1.0
    end
  end
end

defmodule ZaqWeb.AgentControllerTest do
  use ZaqWeb.ConnCase, async: true

  setup do
    Application.put_env(:zaq, :agent_prompt_guard_module, __MODULE__.PromptGuardStub)
    Application.put_env(:zaq, :agent_retrieval_module, __MODULE__.RetrievalStub)
    Application.put_env(:zaq, :agent_document_processor_module, __MODULE__.DocumentProcessorStub)
    Application.put_env(:zaq, :agent_answering_module, __MODULE__.AnsweringStub)

    on_exit(fn ->
      Application.delete_env(:zaq, :agent_prompt_guard_module)
      Application.delete_env(:zaq, :agent_retrieval_module)
      Application.delete_env(:zaq, :agent_document_processor_module)
      Application.delete_env(:zaq, :agent_answering_module)
    end)

    :ok
  end

  describe "POST /api/ask" do
    test "returns answer when pipeline succeeds", %{conn: conn} do
      conn = post(conn, ~p"/api/ask", %{"question" => "ok"})

      assert %{"answer" => "safe answer", "confidence" => 0.88, "language" => "en"} =
               json_response(conn, 200)
    end

    test "returns cleaned answer and zero confidence for no-answer output", %{conn: conn} do
      conn = post(conn, ~p"/api/ask", %{"question" => "no_answer"})

      assert %{"answer" => "No answer available", "confidence" => 0, "language" => "en"} =
               json_response(conn, 200)
    end

    test "returns fallback message when there are no relevant chunks", %{conn: conn} do
      conn = post(conn, ~p"/api/ask", %{"question" => "no_hits"})

      assert %{"answer" => "No relevant information found.", "confidence" => 0} =
               json_response(conn, 200)
    end

    test "returns blocked when prompt guard rejects input", %{conn: conn} do
      conn = post(conn, ~p"/api/ask", %{"question" => "blocked"})

      assert %{"error" => "blocked"} = json_response(conn, 403)
    end

    test "returns internal_error when pipeline fails", %{conn: conn} do
      conn = post(conn, ~p"/api/ask", %{"question" => "retrieval_error"})

      assert %{"error" => "internal_error"} = json_response(conn, 500)
    end
  end

  describe "POST /api/ingest" do
    test "uses folder ingestion path for directory", %{conn: conn} do
      tmp_dir =
        Path.join(System.tmp_dir!(), "zaq-agent-ingest-dir-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf(tmp_dir) end)

      conn = post(conn, ~p"/api/ingest", %{"path" => tmp_dir})

      assert %{"status" => "accepted", "result" => %{"failed" => 0, "processed" => 2}} =
               json_response(conn, 202)
    end

    test "uses single-file ingestion path for file", %{conn: conn} do
      tmp_file =
        Path.join(
          System.tmp_dir!(),
          "zaq-agent-ingest-file-#{System.unique_integer([:positive])}.md"
        )

      File.write!(tmp_file, "# test")
      on_exit(fn -> File.rm(tmp_file) end)

      conn = post(conn, ~p"/api/ingest", %{"path" => tmp_file})

      assert %{"status" => "accepted", "result" => %{"source" => "single"}} =
               json_response(conn, 202)
    end

    test "returns error when ingestion fails", %{conn: conn} do
      conn = post(conn, ~p"/api/ingest", %{"path" => "error_file.md"})

      assert %{"error" => ":ingest_failed"} = json_response(conn, 422)
    end
  end

  defmodule PromptGuardStub do
    def validate("blocked"), do: {:error, {:leaked, "prompt injection"}}
    def validate(question), do: {:ok, "clean:" <> question}

    def output_safe?("unsafe"), do: {:error, {:leaked, "unsafe output"}}
    def output_safe?(answer), do: {:ok, answer}
  end

  defmodule RetrievalStub do
    def ask("clean:retrieval_error", history: _history), do: {:error, :retrieval_failed}

    def ask(clean_msg, history: _history) do
      {:ok, %{"query" => "query:" <> clean_msg, "language" => "en"}}
    end
  end

  defmodule DocumentProcessorStub do
    def similarity_search_count("query:clean:no_hits"), do: {:ok, [%{"total_count" => 0}]}
    def similarity_search_count(_query), do: {:ok, [%{"total_count" => 2}]}

    def query_extraction(query), do: {:ok, [%{"content" => "ctx:" <> query}]}

    def process_folder(_path), do: {:ok, %{processed: 2, failed: 0}}
    def process_single_file("error_file.md", _role_id), do: {:error, :ingest_failed}
    def process_single_file(_path, _role_id), do: {:ok, %{source: "single"}}
  end

  defmodule AnsweringStub do
    def ask([%{"content" => "ctx:query:clean:no_answer"}], history: _history) do
      {:ok, %{answer: "NO_ANSWER: No answer available", confidence: %{score: 0.42}}}
    end

    def ask(_query_results, history: _history) do
      {:ok, %{answer: "safe answer", confidence: %{score: 0.88}}}
    end

    def no_answer?("NO_ANSWER: " <> _rest), do: true
    def no_answer?(_), do: false

    def clean_answer("NO_ANSWER: " <> rest), do: rest
    def clean_answer(answer), do: answer
  end
end

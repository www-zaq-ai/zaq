defmodule ZaqWeb.PendingQuestionsControllerTest do
  use ZaqWeb.ConnCase, async: true

  setup do
    Application.put_env(:zaq, :feature_store_module, __MODULE__.FeatureStoreStub)
    Application.put_env(:zaq, :engine_router_module, __MODULE__.RouterStub)
    Application.put_env(:zaq, :knowledge_gap_module, __MODULE__.KnowledgeGapStub)

    Process.put(:feature_loaded?, true)
    Process.delete(:knowledge_gap_result)

    on_exit(fn ->
      Application.delete_env(:zaq, :feature_store_module)
      Application.delete_env(:zaq, :engine_router_module)
      Application.delete_env(:zaq, :knowledge_gap_module)
      Process.delete(:feature_loaded?)
      Process.delete(:knowledge_gap_result)
    end)

    :ok
  end

  describe "POST /api/pending-questions" do
    test "returns forbidden when feature is not licensed", %{conn: conn} do
      Process.put(:feature_loaded?, false)

      conn = post(conn, ~p"/api/pending-questions", valid_payload())

      assert %{"error" => "feature_not_licensed", "feature" => "knowledge_gap"} =
               json_response(conn, 403)
    end

    test "returns bad_request when required fields are missing", %{conn: conn} do
      conn =
        post(conn, ~p"/api/pending-questions", %{
          "question_id" => 42,
          "question" => "Where is my answer?"
        })

      assert %{"error" => "missing_fields", "fields" => ["channel_id"]} =
               json_response(conn, 400)
    end

    test "posts question successfully and wires callback", %{conn: conn} do
      conn = post(conn, ~p"/api/pending-questions", valid_payload(%{"channel_id" => "ok"}))

      assert %{"status" => "ok", "post_id" => "post-123"} = json_response(conn, 200)

      assert_receive {:dispatch_called, "ok", formatted, callback_fun}
      assert formatted =~ "How do I renew my medical license in Dubai?"
      assert formatted =~ "Reply to this thread with the answer."

      assert is_function(callback_fun, 1)

      assert :ok = callback_fun.("resolved answer")

      assert_receive {:knowledge_gap_resolve_called, 42, "resolved answer", "chunks"}
    end

    test "returns bad_gateway when posting fails", %{conn: conn} do
      conn = post(conn, ~p"/api/pending-questions", valid_payload(%{"channel_id" => "fail"}))

      assert %{"error" => "failed_to_post", "detail" => ":mattermost_down"} =
               json_response(conn, 502)
    end
  end

  defp valid_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "question_id" => 42,
        "question" => "How do I renew my medical license in Dubai?",
        "language" => "en",
        "source_type" => "chat_widget",
        "channel_id" => "ok"
      },
      overrides
    )
  end

  defmodule FeatureStoreStub do
    def feature_loaded?("knowledge_gap"), do: Process.get(:feature_loaded?, true)
  end

  defmodule RouterStub do
    def dispatch_question(channel_id, question, callback) do
      send(self(), {:dispatch_called, channel_id, question, callback})

      case channel_id do
        "ok" -> {:ok, "post-123"}
        "fail" -> {:error, :mattermost_down}
      end
    end
  end

  defmodule KnowledgeGapStub do
    def resolve(question_id, answer, table_name) do
      send(self(), {:knowledge_gap_resolve_called, question_id, answer, table_name})
      Process.get(:knowledge_gap_result, {:ok, :resolved})
    end
  end
end

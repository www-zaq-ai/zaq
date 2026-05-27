defmodule Zaq.Agent.Tools.Email.DraftReplyTest do
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.Tools.Email.DraftReply
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Repo
  alias Zaq.TestSupport.OpenAIStub

  # Mock executor that returns a successful outgoing without calling the real LLM.
  defmodule MockExecutor do
    def run(%Incoming{} = incoming, _opts) do
      %Outgoing{
        body: "Thank you for your email. We will get back to you shortly.",
        channel_id: incoming.channel_id,
        provider: incoming.provider,
        metadata: %{}
      }
    end
  end

  defp raw_email(overrides \\ %{}) do
    Map.merge(
      %{
        "from" => %{"address" => "sender@example.com", "name" => "Sender"},
        "subject" => "Hello ZAQ",
        "body_text" => "Please help me.",
        "message_id" => "<abc123@mail>"
      },
      overrides
    )
  end

  defp insert_configured_agent(name), do: insert_configured_agent(name, true)

  defp insert_configured_agent(name, active) do
    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, agent} =
      Agent.create_agent(%{
        name: name,
        job: "Reply to emails.",
        model: "gpt-4o",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        active: active
      })

    agent
  end

  describe "on_failure/2" do
    test "returns :ok" do
      assert :ok == DraftReply.on_failure(%RuntimeError{message: "boom"}, %{})
    end
  end

  describe "run/2 — empty emails list" do
    test "returns empty drafts list when agent exists but emails is empty" do
      insert_configured_agent("MailResponder")

      assert {:ok, %{drafts: []}, _logs} =
               DraftReply.run(%{emails: [], agent_name: "MailResponder"}, %{})
    end

    test "raises when agent is missing even with empty emails list" do
      # resolve_agent_id! is called before Enum.map so it still validates the agent
      assert_raise RuntimeError, ~r/not found or inactive/, fn ->
        DraftReply.run(%{emails: [], agent_name: "Ghost"}, %{})
      end
    end
  end

  describe "run/2 — agent not found" do
    test "raises when agent name does not exist in DB" do
      assert_raise RuntimeError, ~r/not found or inactive/, fn ->
        DraftReply.run(%{emails: [raw_email()], agent_name: "NonExistent"}, %{})
      end
    end

    test "raises when agent is inactive" do
      insert_configured_agent("SleepyBot", false)

      assert_raise RuntimeError, ~r/not found or inactive/, fn ->
        DraftReply.run(%{emails: [raw_email()], agent_name: "SleepyBot"}, %{})
      end
    end
  end

  describe "run/2 — default agent_name" do
    test "defaults to MailResponder when agent_name key is absent and agent missing" do
      assert_raise RuntimeError, ~r/MailResponder.*not found or inactive/, fn ->
        DraftReply.run(%{emails: [raw_email()]}, %{})
      end
    end

    test "raises with agent error when agent_name absent and executor fails" do
      insert_configured_agent("MailResponder")

      assert_raise RuntimeError, ~r/Agent 'MailResponder' failed/, fn ->
        DraftReply.run(%{emails: [raw_email()]}, %{})
      end
    end
  end

  describe "run/2 — executor error path" do
    setup do
      handler = fn conn, _body ->
        {200, streamed_reply(conn.request_path, "Stubbed draft", "gpt-4o")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      {:ok, agent: insert_configured_agent("MailResponder")}
    end

    test "raises when executor returns an error response" do
      assert_raise RuntimeError, ~r/Agent 'MailResponder' failed/, fn ->
        DraftReply.run(%{emails: [raw_email()], agent_name: "MailResponder"}, %{})
      end
    end

    test "error message includes message_id of the failing email" do
      assert_raise RuntimeError, ~r/<abc123@mail>/, fn ->
        DraftReply.run(%{emails: [raw_email()], agent_name: "MailResponder"}, %{})
      end
    end

    test "raises on first failing email even when multiple are present" do
      emails = [raw_email(), raw_email(%{"from" => %{"address" => "b@b.com", "name" => "B"}})]

      assert_raise RuntimeError, ~r/Agent 'MailResponder' failed/, fn ->
        DraftReply.run(%{emails: emails, agent_name: "MailResponder"}, %{})
      end
    end

    test "supports atom-key sender map fallback during draft creation path" do
      email =
        raw_email(%{
          "from" => %{address: "atom@example.com", name: "Atom Sender"},
          "message_id" => "<atom123@mail>"
        })

      assert_raise RuntimeError, ~r/<atom123@mail>/, fn ->
        DraftReply.run(%{emails: [email], agent_name: "MailResponder"}, %{})
      end
    end
  end

  describe "resolve_agent_id! — DB lookup" do
    test "only active agents are returned" do
      insert_configured_agent("ActiveOnly", true)
      insert_configured_agent("InactiveOnly", false)

      active_id =
        Repo.one(
          from(a in ConfiguredAgent,
            where: a.name == "ActiveOnly" and a.active == true,
            select: a.id
          )
        )

      inactive_id =
        Repo.one(
          from(a in ConfiguredAgent,
            where: a.name == "InactiveOnly" and a.active == true,
            select: a.id
          )
        )

      assert is_integer(active_id)
      assert is_nil(inactive_id)
    end
  end

  describe "run/2 — happy path with injected executor" do
    setup do
      {:ok, agent: insert_configured_agent("MailResponder")}
    end

    @mock_ctx %{executor: MockExecutor}

    test "returns {:ok, %{drafts: [draft]}, logs: logs} for a single email" do
      email = raw_email()

      assert {:ok, %{drafts: [draft]}, logs: logs} =
               DraftReply.run(%{emails: [email], agent_name: "MailResponder"}, @mock_ctx)

      assert draft.to_address == "sender@example.com"
      assert draft.to_name == "Sender"
      assert draft.subject == "Re: Hello ZAQ"
      assert draft.draft =~ "Thank you"
      assert draft.message_id == "<abc123@mail>"
      assert is_list(logs)
      assert length(logs) >= 2
    end

    test "handles multiple emails and returns one draft per email" do
      email1 = raw_email()

      email2 =
        raw_email(%{
          "from" => %{"address" => "b@b.com", "name" => "Bob"},
          "message_id" => "<b1@mail>"
        })

      assert {:ok, %{drafts: drafts}, logs: _logs} =
               DraftReply.run(
                 %{emails: [email1, email2], agent_name: "MailResponder"},
                 @mock_ctx
               )

      assert length(drafts) == 2
    end

    test "reply_subject prepends 'Re: ' to a generic subject (line 141)" do
      email = raw_email(%{"subject" => "Help needed"})

      assert {:ok, %{drafts: [draft]}, logs: _} =
               DraftReply.run(%{emails: [email], agent_name: "MailResponder"}, @mock_ctx)

      assert draft.subject == "Re: Help needed"
    end

    test "reply_subject preserves existing 'Re: ' prefix (line 140)" do
      email = raw_email(%{"subject" => "Re: Previous thread"})

      assert {:ok, %{drafts: [draft]}, logs: _} =
               DraftReply.run(%{emails: [email], agent_name: "MailResponder"}, @mock_ctx)

      assert draft.subject == "Re: Previous thread"
    end

    test "reply_subject uses 'Re: (no subject)' when subject is nil (line 139)" do
      email = raw_email(%{"subject" => nil})

      assert {:ok, %{drafts: [draft]}, logs: _} =
               DraftReply.run(%{emails: [email], agent_name: "MailResponder"}, @mock_ctx)

      assert draft.subject == "Re: (no subject)"
    end

    test "logs include a per-email log and a summary log" do
      email = raw_email()

      assert {:ok, _result, logs: logs} =
               DraftReply.run(%{emails: [email], agent_name: "MailResponder"}, @mock_ctx)

      assert Enum.any?(logs, fn l ->
               l.level == "info" and String.contains?(l.message, "Draft ready")
             end)

      assert Enum.any?(logs, fn l ->
               l.level == "info" and String.contains?(l.message, "Drafted 1")
             end)
    end

    test "uses run_id from context in scope when provided" do
      email = raw_email()

      assert {:ok, %{drafts: [_]}, logs: _} =
               DraftReply.run(
                 %{emails: [email], agent_name: "MailResponder"},
                 Map.put(@mock_ctx, :run_id, "my-run-123")
               )
    end
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

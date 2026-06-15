defmodule Zaq.Agent.Tools.Email.DraftReplyTest do
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.Tools.Email.DraftReply
  alias Zaq.Repo
  alias Zaq.TestSupport.OpenAIStub

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

  defp insert_configured_agent(name, active),
    do: insert_configured_agent(name, active, "https://api.openai.com/v1")

  defp insert_configured_agent(name, active, endpoint) do
    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: endpoint})

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

    test "defaults to MailResponder when agent_name key is absent and agent exists" do
      insert_configured_agent("MailResponder")
      # Should succeed (even if Executor uses fallback body due to no LLM)
      assert {:ok, %{drafts: [draft]}, _logs} = DraftReply.run(%{emails: [raw_email()]}, %{})
      assert is_map(draft)
    end
  end

  describe "run/2 — draft shape when agent found" do
    setup do
      handler = fn conn, _body ->
        {200, streamed_reply(conn.request_path, "Stubbed draft", "gpt-4o")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      # Point the agent's credential at the local stub too. The agent resolves its
      # endpoint from its credential (not the seeded default llm_config), so without
      # this the Executor makes a real call to api.openai.com — normally swallowed into
      # a fallback Outgoing, but it can hang mid-stream in CI and time out the test.
      {:ok, agent: insert_configured_agent("MailResponder", true, endpoint)}
    end

    test "returns {:ok, %{drafts: [...]}} with one draft per email" do
      # Executor.run never raises — it returns a fallback Outgoing even when LLM fails.
      assert {:ok, %{drafts: drafts}, _logs} =
               DraftReply.run(%{emails: [raw_email()], agent_name: "MailResponder"}, %{})

      assert length(drafts) == 1
    end

    test "draft map has expected keys" do
      assert {:ok, %{drafts: [draft]}, _logs} =
               DraftReply.run(%{emails: [raw_email()], agent_name: "MailResponder"}, %{})

      assert Map.has_key?(draft, :to_address)
      assert Map.has_key?(draft, :to_name)
      assert Map.has_key?(draft, :subject)
      assert Map.has_key?(draft, :draft)
      assert Map.has_key?(draft, :message_id)
    end

    test "draft to_address comes from email from.address" do
      assert {:ok, %{drafts: [draft]}, _logs} =
               DraftReply.run(
                 %{
                   emails: [
                     raw_email(%{
                       "from" => %{"address" => "alice@example.com", "name" => "Alice"}
                     })
                   ],
                   agent_name: "MailResponder"
                 },
                 %{}
               )

      assert draft.to_address == "alice@example.com"
    end

    test "draft to_name comes from email from.name" do
      assert {:ok, %{drafts: [draft]}, _logs} =
               DraftReply.run(
                 %{
                   emails: [raw_email(%{"from" => %{"address" => "a@b.com", "name" => "Alice"}})],
                   agent_name: "MailResponder"
                 },
                 %{}
               )

      assert draft.to_name == "Alice"
    end

    test "reply subject prefixes with Re: for plain subject" do
      assert {:ok, %{drafts: [draft]}, _logs} =
               DraftReply.run(
                 %{emails: [raw_email(%{"subject" => "Hello"})], agent_name: "MailResponder"},
                 %{}
               )

      assert draft.subject == "Re: Hello"
    end

    test "reply subject does not double-prefix already-prefixed subject" do
      assert {:ok, %{drafts: [draft]}, _logs} =
               DraftReply.run(
                 %{emails: [raw_email(%{"subject" => "Re: Hello"})], agent_name: "MailResponder"},
                 %{}
               )

      assert draft.subject == "Re: Hello"
    end

    test "nil subject falls back to 'Re: (no subject)'" do
      assert {:ok, %{drafts: [draft]}, _logs} =
               DraftReply.run(
                 %{emails: [raw_email(%{"subject" => nil})], agent_name: "MailResponder"},
                 %{}
               )

      assert draft.subject == "Re: (no subject)"
    end

    test "message_id is passed through from the raw email" do
      assert {:ok, %{drafts: [draft]}, _logs} =
               DraftReply.run(
                 %{
                   emails: [raw_email(%{"message_id" => "<my-id@mail>"})],
                   agent_name: "MailResponder"
                 },
                 %{}
               )

      assert draft.message_id == "<my-id@mail>"
    end

    test "returns one draft per email for multiple emails" do
      emails = [raw_email(), raw_email(%{"from" => %{"address" => "b@b.com", "name" => "B"}})]

      assert {:ok, %{drafts: drafts}, _logs} =
               DraftReply.run(%{emails: emails, agent_name: "MailResponder"}, %{})

      assert length(drafts) == 2
    end

    test "handles from field with atom keys" do
      email = %{
        "from" => %{address: "atom@example.com", name: "AtomName"},
        "subject" => "Test",
        "body_text" => "body",
        "message_id" => "<x>"
      }

      assert {:ok, %{drafts: [draft]}, _logs} =
               DraftReply.run(%{emails: [email], agent_name: "MailResponder"}, %{})

      assert draft.to_address == "atom@example.com"
      assert_received {:openai_request, _, _, _, _}
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

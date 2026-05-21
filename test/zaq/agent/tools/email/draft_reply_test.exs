defmodule Zaq.Agent.Tools.Email.DraftReplyTest do
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.Tools.Email.DraftReply
  alias Zaq.Repo

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
end

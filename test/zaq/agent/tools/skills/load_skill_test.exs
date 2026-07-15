defmodule Zaq.Agent.Tools.Skills.LoadSkillTest do
  use Zaq.DataCase, async: true

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.Skills
  alias Zaq.Agent.Tools.Skills.LoadSkill

  defp skill!(attrs) do
    {:ok, skill} =
      %{
        name: "calculator",
        description: "Precise arithmetic.",
        body: "# Calculator\nUse the tools, not mental math.",
        tags: []
      }
      |> Map.merge(attrs)
      |> Skills.create_skill()

    skill
  end

  defp agent!(attrs) do
    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, agent} =
      %{
        name: "assistant-#{System.unique_integer([:positive])}",
        job: "Help.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        active: true,
        enabled_tool_keys: []
      }
      |> Map.merge(attrs)
      |> Agent.create_agent()

    agent
  end

  defp ctx(agent), do: %{configured_agent_id: agent.id}

  defmodule RaisingTelemetry do
    def execute(_event, _measurements, _metadata), do: raise("telemetry offline")
  end

  describe "loading a granted skill" do
    test "returns the skill's full instructions" do
      skill = skill!(%{name: "calculator", body: "SECRET_INSTRUCTIONS"})
      agent = agent!(%{enabled_skill_ids: [skill.id]})

      assert {:ok, result} = LoadSkill.run(%{name: "calculator"}, ctx(agent))

      assert result.name == "calculator"
      assert result.instructions == "SECRET_INSTRUCTIONS"
      assert result.resources == []
    end

    test "is idempotent — a repeat call returns the body again, not an error" do
      skill = skill!(%{name: "calculator"})
      agent = agent!(%{enabled_skill_ids: [skill.id]})

      assert {:ok, first} = LoadSkill.run(%{name: "calculator"}, ctx(agent))
      assert {:ok, second} = LoadSkill.run(%{name: "calculator"}, ctx(agent))
      assert first == second
    end

    test "telemetry failures do not fail the tool call" do
      skill = skill!(%{name: "calculator", body: "one two three"})
      agent = agent!(%{enabled_skill_ids: [skill.id]})

      assert {:ok, result} =
               LoadSkill.run(
                 %{name: "calculator"},
                 Map.put(ctx(agent), :telemetry_module, RaisingTelemetry)
               )

      assert result.name == "calculator"
      assert result.instructions == skill.body
    end
  end

  describe "scoping — the security boundary" do
    test "an agent cannot load a skill it was never granted" do
      _skill = skill!(%{name: "calculator"})
      agent = agent!(%{enabled_skill_ids: []})

      assert {:error, message} = LoadSkill.run(%{name: "calculator"}, ctx(agent))
      assert message =~ "not available to this agent"
    end

    test "agent B cannot load agent A's skill" do
      skill_a = skill!(%{name: "for-agent-a"})
      _agent_a = agent!(%{enabled_skill_ids: [skill_a.id]})
      agent_b = agent!(%{enabled_skill_ids: []})

      assert {:error, _} = LoadSkill.run(%{name: "for-agent-a"}, ctx(agent_b))
    end

    test "an inactive skill reads as not-granted" do
      skill = skill!(%{name: "calculator", active: false})
      agent = agent!(%{enabled_skill_ids: [skill.id]})

      assert {:error, _} = LoadSkill.run(%{name: "calculator"}, ctx(agent))
    end

    test "a hallucinated name is a clean not-found" do
      skill = skill!(%{name: "calculator"})
      agent = agent!(%{enabled_skill_ids: [skill.id]})

      assert {:error, message} = LoadSkill.run(%{name: "does-not-exist"}, ctx(agent))
      assert message =~ "does-not-exist"
    end

    # Upstream Jido's LoadSkill lists every available skill on a miss (G3). ZAQ must not.
    test "the not-found error leaks no other skill names" do
      granted = skill!(%{name: "calculator"})
      _other = skill!(%{name: "top-secret-other-skill"})
      agent = agent!(%{enabled_skill_ids: [granted.id]})

      assert {:error, message} = LoadSkill.run(%{name: "nope"}, ctx(agent))

      refute message =~ "top-secret-other-skill"
      refute message =~ "calculator"
    end
  end

  describe "context guards" do
    test "no configured_agent_id in context → refused, never a global lookup" do
      _skill = skill!(%{name: "calculator"})

      assert {:error, message} = LoadSkill.run(%{name: "calculator"}, %{})
      assert message =~ "not available in this context"
    end

    test "an unknown configured_agent_id → refused" do
      _skill = skill!(%{name: "calculator"})

      assert {:error, _} = LoadSkill.run(%{name: "calculator"}, %{configured_agent_id: 999_999})
    end
  end

  describe "telemetry" do
    test "emits bytes and tokens for the loaded body" do
      skill = skill!(%{name: "calculator", body: "one two three four five"})
      agent = agent!(%{enabled_skill_ids: [skill.id]})

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:zaq, :agent, :skill, :load]])

      LoadSkill.run(%{name: "calculator"}, ctx(agent))

      assert_receive {[:zaq, :agent, :skill, :load], ^ref, measurements, metadata}
      assert measurements.body_bytes == byte_size(skill.body)
      assert measurements.body_tokens > 0
      assert metadata.skill_name == "calculator"
      assert metadata.configured_agent_id == agent.id
    end
  end
end

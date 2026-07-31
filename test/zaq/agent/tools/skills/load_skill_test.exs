defmodule Zaq.Agent.Tools.Skills.LoadSkillTest do
  use Zaq.DataCase, async: true

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.Skills
  alias Zaq.Agent.Tools.Skills.LoadSkill
  alias Zaq.Ingestion.BundleRecords

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

  describe "the resource manifest" do
    # The listing crossing the boundary is records now, so build them the way ingestion does
    # rather than hand-rolling a map that would drift from the real shape.
    defp entry(name, size \\ 128, type \\ "references") do
      BundleRecords.from_entry(
        %{
          name: name,
          relative_path: "#{type}/#{name}",
          size: size,
          modified: ~U[2026-07-30 12:00:00Z]
        },
        ".agents/skills/calculator"
      )
    end

    # A stub router that records what it was asked for, so the request shape can be
    # asserted rather than assumed.
    defmodule RecordingRouter do
      def dispatch(event) do
        send(
          self(),
          {:dispatched, event.next_hop.destination, event.opts[:action], event.request}
        )

        %{event | response: Process.get(:bundle_response)}
      end
    end

    defmodule UnreachableRouter do
      def dispatch(_event), do: raise("ingestion node is down")
    end

    defmodule ExitingRouter do
      def dispatch(_event), do: exit({:timeout, {GenServer, :call, []}})
    end

    defp router_ctx(agent, response) do
      Process.put(:bundle_response, response)
      Map.put(ctx(agent), :node_router, RecordingRouter)
    end

    defp bundled!(attrs \\ %{}) do
      skill =
        skill!(
          Map.merge(%{name: "calculator", resource_root: ".agents/skills/calculator"}, attrs)
        )

      {skill, agent!(%{enabled_skill_ids: [skill.id]})}
    end

    test "lists the skill's bundled files alongside the instructions" do
      {_skill, agent} = bundled!()

      listing = %{references: [entry("pricing.md", 42)], assets: [], scripts: []}

      assert {:ok, result} =
               LoadSkill.run(%{name: "calculator"}, router_ctx(agent, {:ok, listing}))

      assert result.instructions =~ "Calculator"

      assert [%{name: "pricing.md", resource_path: "references/pricing.md", size: 42}] =
               result.resources
    end

    test "the dispatched request is exactly %{bundle: locator}" do
      # Asserted, so a future edit that slips a volume into the payload fails here.
      {_skill, agent} = bundled!()
      listing = %{references: [], assets: [], scripts: []}

      LoadSkill.run(%{name: "calculator"}, router_ctx(agent, {:ok, listing}))

      assert_receive {:dispatched, :ingestion, :list_skill_bundle, request}
      assert request == %{bundle: ".agents/skills/calculator"}
      assert Map.keys(request) == [:bundle]
    end

    test "orders references ahead of assets and scripts" do
      {_skill, agent} = bundled!()

      listing = %{
        references: [entry("ref.md")],
        assets: [entry("logo.png", 9, "assets")],
        scripts: [entry("run.sh", 3, "scripts")]
      }

      assert {:ok, result} =
               LoadSkill.run(%{name: "calculator"}, router_ctx(agent, {:ok, listing}))

      assert Enum.map(result.resources, & &1.name) == ["ref.md", "logo.png", "run.sh"]
    end

    test "entries carry no absolute path and no timestamp" do
      {_skill, agent} = bundled!()
      listing = %{references: [entry("pricing.md")], assets: [], scripts: []}

      assert {:ok, result} =
               LoadSkill.run(%{name: "calculator"}, router_ctx(agent, {:ok, listing}))

      assert [entry] = result.resources
      assert Map.keys(entry) |> Enum.sort() == [:name, :resource_path, :size]
      refute inspect(entry) =~ "absolute_path"
    end

    test "a skill with no bundle returns [] and dispatches nothing" do
      skill = skill!(%{name: "calculator"})
      agent = agent!(%{enabled_skill_ids: [skill.id]})

      assert {:ok, result} =
               LoadSkill.run(%{name: "calculator"}, router_ctx(agent, {:ok, :unused}))

      assert result.resources == []
      refute_receive {:dispatched, _, _, _}
    end

    test "an ingestion error still returns the instructions" do
      {_skill, agent} = bundled!()

      assert {:ok, result} =
               LoadSkill.run(%{name: "calculator"}, router_ctx(agent, {:error, :no_volumes}))

      assert result.instructions =~ "Calculator"
      assert result.resources == []
    end

    test "an unreachable ingestion node still returns the instructions" do
      {_skill, agent} = bundled!()
      context = Map.put(ctx(agent), :node_router, UnreachableRouter)

      assert {:ok, result} = LoadSkill.run(%{name: "calculator"}, context)
      assert result.instructions =~ "Calculator"
      assert result.resources == []
    end

    test "a dispatch timeout still returns the instructions" do
      # A GenServer call timeout exits rather than raising — losing the manifest to it must
      # not lose the skill body too.
      {_skill, agent} = bundled!()
      context = Map.put(ctx(agent), :node_router, ExitingRouter)

      assert {:ok, result} = LoadSkill.run(%{name: "calculator"}, context)
      assert result.instructions =~ "Calculator"
      assert result.resources == []
    end

    test "a listing over the cap is truncated and states the real total" do
      {_skill, agent} = bundled!()
      entries = for i <- 1..137, do: entry("file-#{i}.md")
      listing = %{references: entries, assets: [], scripts: []}

      context =
        agent
        |> router_ctx({:ok, listing})
        |> Map.put(:limits_opts, [])

      assert {:ok, result} = LoadSkill.run(%{name: "calculator"}, context)

      assert length(result.resources) == 100
      assert result.resources_note =~ "Showing 100 of 137"
    end

    test "a listing under the cap carries no note" do
      {_skill, agent} = bundled!()
      listing = %{references: [entry("a.md")], assets: [], scripts: []}

      assert {:ok, result} =
               LoadSkill.run(%{name: "calculator"}, router_ctx(agent, {:ok, listing}))

      refute Map.has_key?(result, :resources_note)
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

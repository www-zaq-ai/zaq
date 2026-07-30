defmodule Zaq.Agent.Tools.Skills.LoadSkillResourceTest do
  use Zaq.DataCase, async: true

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.Skills
  alias Zaq.Agent.Tools.Skills.LoadSkillResource

  @locator ".agents/skills/calculator"

  defp skill!(attrs) do
    {:ok, skill} =
      %{
        name: "calculator",
        description: "Precise arithmetic.",
        body: "# Calculator",
        resource_root: @locator,
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

  defmodule RecordingRouter do
    def dispatch(event) do
      send(self(), {:dispatched, event.next_hop.destination, event.opts[:action], event.request})
      %{event | response: Process.get(:bundle_response)}
    end
  end

  defmodule RaisingTelemetry do
    def execute(_event, _measurements, _metadata), do: raise("telemetry offline")
  end

  defp ctx(agent, response) do
    Process.put(:bundle_response, response)
    %{configured_agent_id: agent.id, node_router: RecordingRouter}
  end

  defp granted!(skill_attrs \\ %{}) do
    skill = skill!(skill_attrs)
    {skill, agent!(%{enabled_skill_ids: [skill.id]})}
  end

  describe "reading a granted skill's resource" do
    test "returns the file's text" do
      {_skill, agent} = granted!()

      assert {:ok, result} =
               LoadSkillResource.run(
                 %{skill_name: "calculator", resource_path: "references/pricing.md"},
                 ctx(agent, {:ok, "# Pricing 2026"})
               )

      assert result.skill_name == "calculator"
      assert result.resource_path == "references/pricing.md"
      assert result.content == "# Pricing 2026"
    end

    test "dispatches exactly %{bundle: locator, resource: resource_path}" do
      {_skill, agent} = granted!()

      LoadSkillResource.run(
        %{skill_name: "calculator", resource_path: "references/pricing.md"},
        ctx(agent, {:ok, "body"})
      )

      assert_receive {:dispatched, :ingestion, :read_skill_bundle_resource, request}
      assert request == %{bundle: @locator, resource: "references/pricing.md"}
      assert Map.keys(request) |> Enum.sort() == [:bundle, :resource]
    end

    test "passes the resource_path through byte-for-byte" do
      # The manifest handed the model this exact string; rewriting it here could only let it
      # reach a file it did not name.
      {_skill, agent} = granted!()
      path = "references/sub dir/Q3 Report (final).md"

      LoadSkillResource.run(
        %{skill_name: "calculator", resource_path: path},
        ctx(agent, {:ok, "body"})
      )

      assert_receive {:dispatched, _, _, %{resource: ^path}}
    end

    test "reads an asset that happens to be text" do
      {_skill, agent} = granted!()

      assert {:ok, result} =
               LoadSkillResource.run(
                 %{skill_name: "calculator", resource_path: "assets/notes.txt"},
                 ctx(agent, {:ok, "plain"})
               )

      assert result.content == "plain"
    end
  end

  describe "scoping — the security boundary" do
    test "a skill not attached to this agent is refused" do
      _skill = skill!(%{name: "calculator"})
      agent = agent!(%{enabled_skill_ids: []})

      assert {:error, message} =
               LoadSkillResource.run(
                 %{skill_name: "calculator", resource_path: "references/pricing.md"},
                 ctx(agent, {:ok, "SHOULD NOT BE REACHED"})
               )

      assert message =~ "not available to this agent"
      refute_receive {:dispatched, _, _, _}
    end

    test "the refusal names neither the file nor any other skill" do
      granted = skill!(%{name: "calculator"})
      _other = skill!(%{name: "top-secret-other-skill", resource_root: ".agents/skills/other"})
      agent = agent!(%{enabled_skill_ids: [granted.id]})

      assert {:error, message} =
               LoadSkillResource.run(
                 %{skill_name: "nope", resource_path: "references/salaries.md"},
                 ctx(agent, {:ok, "x"})
               )

      refute message =~ "top-secret-other-skill"
      refute message =~ "salaries"
      refute message =~ "calculator"
    end

    test "agent B cannot read agent A's skill resource" do
      skill_a = skill!(%{name: "for-agent-a", resource_root: ".agents/skills/for-agent-a"})
      _agent_a = agent!(%{enabled_skill_ids: [skill_a.id]})
      agent_b = agent!(%{enabled_skill_ids: []})

      assert {:error, _} =
               LoadSkillResource.run(
                 %{skill_name: "for-agent-a", resource_path: "references/a.md"},
                 ctx(agent_b, {:ok, "leak"})
               )
    end

    test "an inactive skill reads as not-granted" do
      skill = skill!(%{name: "calculator", active: false})
      agent = agent!(%{enabled_skill_ids: [skill.id]})

      assert {:error, _} =
               LoadSkillResource.run(
                 %{skill_name: "calculator", resource_path: "references/a.md"},
                 ctx(agent, {:ok, "leak"})
               )
    end

    test "nil configured_agent_id is refused, never a global lookup" do
      _skill = skill!(%{name: "calculator"})

      assert {:error, message} =
               LoadSkillResource.run(
                 %{skill_name: "calculator", resource_path: "references/a.md"},
                 %{node_router: RecordingRouter}
               )

      assert message =~ "not available in this context"
      refute_receive {:dispatched, _, _, _}
    end

    test "an unknown configured_agent_id is refused" do
      _skill = skill!(%{name: "calculator"})

      assert {:error, _} =
               LoadSkillResource.run(
                 %{skill_name: "calculator", resource_path: "references/a.md"},
                 %{configured_agent_id: 999_999, node_router: RecordingRouter}
               )
    end
  end

  describe "path refusals" do
    test "a scripts/ path is refused without dispatching" do
      {_skill, agent} = granted!()

      assert {:error, message} =
               LoadSkillResource.run(
                 %{skill_name: "calculator", resource_path: "scripts/deploy.sh"},
                 ctx(agent, {:ok, "rm -rf /"})
               )

      assert message =~ "Scripts are not readable"
      refute_receive {:dispatched, _, _, _}
    end

    test "a nested scripts/ path is refused too" do
      {_skill, agent} = granted!()

      assert {:error, _} =
               LoadSkillResource.run(
                 %{skill_name: "calculator", resource_path: "scripts/nested/deploy.sh"},
                 ctx(agent, {:ok, "payload"})
               )

      refute_receive {:dispatched, _, _, _}
    end

    test "traversal is refused by the ingestion side and surfaced usably" do
      {_skill, agent} = granted!()

      assert {:error, message} =
               LoadSkillResource.run(
                 %{skill_name: "calculator", resource_path: "../../../etc/passwd"},
                 ctx(agent, {:error, :path_traversal})
               )

      assert message =~ "not a valid resource path"
    end

    test "an absolute path is refused" do
      {_skill, agent} = granted!()

      assert {:error, message} =
               LoadSkillResource.run(
                 %{skill_name: "calculator", resource_path: "/etc/passwd"},
                 ctx(agent, {:error, :path_traversal})
               )

      assert message =~ "not a valid resource path"
    end

    test "a bare filename is refused" do
      {_skill, agent} = granted!()

      assert {:error, message} =
               LoadSkillResource.run(
                 %{skill_name: "calculator", resource_path: "pricing.md"},
                 ctx(agent, {:error, :invalid_resource_path})
               )

      assert message =~ "not a valid resource path"
    end
  end

  describe "content failures are usable messages, not crashes" do
    test "a binary resource explains itself" do
      {_skill, agent} = granted!()

      assert {:error, message} =
               LoadSkillResource.run(
                 %{skill_name: "calculator", resource_path: "assets/logo.png"},
                 ctx(agent, {:error, :invalid_utf8})
               )

      assert message =~ "binary file"
      assert message =~ "cannot be read as text"
    end

    test "a missing file points back at load_skill" do
      {_skill, agent} = granted!()

      assert {:error, message} =
               LoadSkillResource.run(
                 %{skill_name: "calculator", resource_path: "references/absent.md"},
                 ctx(agent, {:error, :not_found})
               )

      assert message =~ "load_skill"
    end

    test "a skill with no bundle says so" do
      skill = skill!(%{name: "calculator", resource_root: nil})
      agent = agent!(%{enabled_skill_ids: [skill.id]})

      assert {:error, message} =
               LoadSkillResource.run(
                 %{skill_name: "calculator", resource_path: "references/a.md"},
                 ctx(agent, {:ok, "unused"})
               )

      assert message =~ "no bundled files"
      refute_receive {:dispatched, _, _, _}
    end

    test "an unreachable ingestion node degrades to a retryable message" do
      {_skill, agent} = granted!()

      assert {:error, message} =
               LoadSkillResource.run(
                 %{skill_name: "calculator", resource_path: "references/a.md"},
                 ctx(agent, {:error, :no_volumes})
               )

      assert message =~ "could not be read right now"
    end
  end

  describe "the read cap" do
    test "an oversize file is refused with its size named, not truncated" do
      {_skill, agent} = granted!()
      body = String.duplicate("x", 300_000)

      assert {:error, message} =
               LoadSkillResource.run(
                 %{skill_name: "calculator", resource_path: "references/huge.md"},
                 ctx(agent, {:ok, body})
               )

      assert message =~ "300000 bytes"
      assert message =~ "262144"
      refute message =~ "xxxx"
    end

    test "a file exactly at the cap is returned" do
      {_skill, agent} = granted!()
      body = String.duplicate("x", 262_144)

      assert {:ok, result} =
               LoadSkillResource.run(
                 %{skill_name: "calculator", resource_path: "references/exact.md"},
                 ctx(agent, {:ok, body})
               )

      assert byte_size(result.content) == 262_144
    end

    test "the cap is overridable" do
      {_skill, agent} = granted!()

      context =
        agent
        |> ctx({:ok, "0123456789"})
        |> Map.put(:limits_opts, config: __MODULE__.TinyLimits)

      assert {:error, message} =
               LoadSkillResource.run(
                 %{skill_name: "calculator", resource_path: "references/small.md"},
                 context
               )

      assert message =~ "10 bytes"
    end

    defmodule TinyLimits do
      def get(:zaq, :agent_skills, _default, _opts), do: %{resource_read_max_bytes: 4}
      def get(app, key, default, _opts), do: Application.get_env(app, key, default)
    end
  end

  describe "telemetry" do
    test "emits bytes and tokens for the returned file" do
      {skill, agent} = granted!()

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:zaq, :agent, :skill, :resource_load]])

      LoadSkillResource.run(
        %{skill_name: "calculator", resource_path: "references/pricing.md"},
        ctx(agent, {:ok, "one two three four five"})
      )

      assert_receive {[:zaq, :agent, :skill, :resource_load], ^ref, measurements, metadata}
      assert measurements.bytes == byte_size("one two three four five")
      assert measurements.tokens > 0
      assert metadata.skill_name == "calculator"
      assert metadata.skill_id == skill.id
      assert metadata.resource_path == "references/pricing.md"
      assert metadata.configured_agent_id == agent.id
    end

    test "a telemetry failure does not fail the call" do
      {_skill, agent} = granted!()

      context =
        agent
        |> ctx({:ok, "body"})
        |> Map.put(:telemetry_module, RaisingTelemetry)

      assert {:ok, result} =
               LoadSkillResource.run(
                 %{skill_name: "calculator", resource_path: "references/a.md"},
                 context
               )

      assert result.content == "body"
    end
  end

  describe "auto-provisioning" do
    test "appears with the first skill and disappears with the last" do
      skill = skill!(%{name: "calculator"})
      agent = agent!(%{enabled_skill_ids: []})

      assert "skills.load_skill_resource" not in Skills.provisioned_tool_keys(agent, [])

      keys = Skills.provisioned_tool_keys(agent, [skill])
      assert "skills.load_skill_resource" in keys
      assert "skills.load_skill" in keys
    end

    test "is a valid registry key" do
      assert Zaq.Agent.Tools.Registry.valid_tool_key?("skills.load_skill_resource")
    end

    test "rides the same condition as load_skill" do
      # Splitting them would let the tool vanish mid-conversation while a manifest the model
      # already read still points at it.
      skill = skill!(%{name: "calculator", resource_root: nil})
      agent = agent!(%{enabled_skill_ids: []})

      keys = Skills.provisioned_tool_keys(agent, [skill])
      assert "skills.load_skill_resource" in keys
    end
  end
end

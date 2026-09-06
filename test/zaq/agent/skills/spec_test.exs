defmodule Zaq.Agent.Skills.SpecTest do
  @moduledoc """
  Conversion of stored skills into native Jido specs. Runtime prompt assertions live
  in FactoryTest, which exercises the production integration.
  """

  use Zaq.DataCase, async: true

  import ExUnit.CaptureLog

  alias Jido.AI.Skill.Spec
  alias Zaq.Agent.Skill
  alias Zaq.Agent.Skills

  @body_marker "SECRET_BODY_MARKER_DO_NOT_LEAK"

  defp skill!(attrs) do
    {:ok, skill} =
      %{
        name: "calculator",
        description: "Precise arithmetic. Use when the user asks for a calculation.",
        body: "# Instructions\n#{@body_marker}",
        provided_tool_keys: [],
        tags: []
      }
      |> Map.merge(attrs)
      |> Skills.create_skill()

    skill
  end

  describe "to_spec/1" do
    test "a valid record becomes a standard %Spec{} with an inline body" do
      skill = skill!(%{tags: ["math"], allowed_tools: ["Read"]})

      assert {:ok, %Spec{} = spec} = Skills.to_spec(skill)

      assert spec.name == "calculator"
      assert spec.body_ref == {:inline, skill.body}
      assert spec.allowed_tools == ["Read"]
      assert spec.tags == ["math"]
    end

    test "resolves through Jido's stateless path — no Registry process required" do
      refute Process.whereis(Jido.AI.Skill.Registry)

      {:ok, spec} = Skills.to_spec(skill!(%{}))

      assert {:ok, ^spec} = Jido.AI.Skill.resolve(spec)
    end

    # ZAQ's provisioning concepts are NOT part of the Open Agent Skills format. Leaking
    # them into the Spec — including into `metadata`, which Jido would happily accept —
    # would make the emitted SKILL.md non-conformant and blur the very distinction the
    # provided/allowed split exists to draw.
    test "no ZAQ field leaks into the Spec" do
      # Built in memory, not inserted: to_spec/1 is a pure conversion, and this keeps the
      # test focused on what crosses the seam rather than on MCP endpoint fixtures.
      skill = %Skill{
        name: "calculator",
        description: "Precise arithmetic.",
        body: "# Instructions\n#{@body_marker}",
        provided_tool_keys: ["answering.search_knowledge_base"],
        enabled_mcp_endpoint_ids: [1, 2],
        tags: []
      }

      {:ok, spec} = Skills.to_spec(skill)

      encoded = inspect(spec)
      refute encoded =~ "answering.search_knowledge_base"
      refute encoded =~ "enabled_mcp_endpoint_ids"
      assert spec.allowed_tools == []
      assert spec.metadata in [nil, %{}]
    end

    test "an invalid record is skipped, not fatal — and is logged, not silent" do
      valid = skill!(%{name: "good-skill"})

      # A row that predates validation: written straight to the DB, bypassing the
      # changeset, exactly as an older node could have left it.
      {:ok, _} =
        Repo.query(
          """
          INSERT INTO agent_skills (name, description, body, provided_tool_keys,
                                    allowed_tools, enabled_mcp_endpoint_ids, tags, active,
                                    inserted_at, updated_at)
          VALUES ('Not Kebab', 'A legacy row with an invalid name.', 'b', '{}', '{}',
                  '{}', '{}', true, NOW(), NOW())
          """,
          []
        )

      broken = Repo.get_by!(Skill, name: "Not Kebab")

      assert {:error, _} = Skills.to_spec(broken)

      log =
        capture_log(fn ->
          assert [%Spec{name: "good-skill"}] = Skills.to_specs([valid, broken])
        end)

      assert log =~ "Not Kebab"
      assert log =~ "omitted from the agent's index"
    end
  end
end

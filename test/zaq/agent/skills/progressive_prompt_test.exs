defmodule Zaq.Agent.Skills.ProgressivePromptTest do
  @moduledoc """
  Steps 3 + 4: the `to_spec/1` seam, and the progressive (index-only) system prompt.

  The load-bearing assertion in this file is that **no skill body ever reaches a system
  prompt**. Everything else is detail.
  """

  use Zaq.DataCase, async: true

  import ExUnit.CaptureLog

  alias Jido.AI.Skill.Spec
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.Skill
  alias Zaq.Agent.Skills
  alias Zaq.Agent.Skills.ProgressivePromptTest.FlagStub

  @body_marker "SECRET_BODY_MARKER_DO_NOT_LEAK"

  defp skill!(attrs) do
    {:ok, skill} =
      %{
        name: "calculator",
        description: "Precise arithmetic. Use when the user asks for a calculation.",
        body: "# Instructions\n#{@body_marker}",
        tool_keys: [],
        tags: []
      }
      |> Map.merge(attrs)
      |> Skills.create_skill()

    skill
  end

  defp agent(attrs \\ %{}) do
    struct(
      %ConfiguredAgent{
        name: "assistant",
        job: "You are a helpful assistant.",
        enabled_tool_keys: [],
        enabled_mcp_endpoint_ids: [],
        enabled_skill_ids: []
      },
      attrs
    )
  end

  describe "to_spec/1 — the seam (Step 3)" do
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
        tool_keys: ["answering.search_knowledge_base"],
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
          INSERT INTO agent_skills (name, description, body, tool_keys, provided_tool_keys,
                                    allowed_tools, enabled_mcp_endpoint_ids, tags, active,
                                    inserted_at, updated_at)
          VALUES ('Not Kebab', 'A legacy row with an invalid name.', 'b', '{}', '{}', '{}',
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

  describe "index_system_prompt/2 — progressive disclosure (Step 4)" do
    test "carries names and descriptions, and ZERO body bytes" do
      skills = [
        skill!(%{name: "calculator", description: "Precise arithmetic."}),
        skill!(%{name: "weather", description: "Forecasts by city."}),
        skill!(%{name: "translator", description: "Translates text."})
      ]

      prompt = Skills.index_system_prompt(agent(), skills)

      for skill <- skills do
        assert prompt =~ skill.name
        assert prompt =~ skill.description
      end

      refute prompt =~ @body_marker
    end

    test "prompt size is O(skill count), not O(total body bytes)" do
      huge = String.duplicate("x", 50_000)

      small = [skill!(%{name: "small", body: "tiny"})]
      large = [skill!(%{name: "large", body: huge})]

      small_prompt = Skills.index_system_prompt(agent(), small)
      large_prompt = Skills.index_system_prompt(agent(), large)

      # A 50KB body must not move the prompt size at all beyond the name difference.
      assert abs(String.length(large_prompt) - String.length(small_prompt)) < 100
      refute large_prompt =~ huge
    end

    test "tells the model how to open a skill — an index it cannot act on is useless" do
      prompt = Skills.index_system_prompt(agent(), [skill!(%{})])

      assert prompt =~ "load_skill"
    end

    test "renders allowed_tools — stored and rendered, though not enforced in Part 1" do
      prompt = Skills.index_system_prompt(agent(), [skill!(%{allowed_tools: ["Read", "Bash"]})])

      assert prompt =~ "Read, Bash"
    end

    test "an agent with zero skills gets its bare job — no header, no dangling separator" do
      assert Skills.index_system_prompt(agent(), []) == "You are a helpful assistant."
    end

    test "an agent whose only skill is invalid still gets a clean prompt" do
      {:ok, _} =
        Repo.query(
          """
          INSERT INTO agent_skills (name, description, body, tool_keys, provided_tool_keys,
                                    allowed_tools, enabled_mcp_endpoint_ids, tags, active,
                                    inserted_at, updated_at)
          VALUES ('Bad Name', 'Legacy.', 'b', '{}', '{}', '{}', '{}', '{}', true, NOW(), NOW())
          """,
          []
        )

      broken = Repo.get_by!(Skill, name: "Bad Name")

      capture_log(fn ->
        assert Skills.index_system_prompt(agent(), [broken]) == "You are a helpful assistant."
      end)
    end
  end

  # The flag is the rollback path for an answer-quality regression, so it must be tested
  # in BOTH directions — an untested off-branch is not a rollback, it is a hope.
  describe ":skills_progressive_disclosure flag" do
    test "ON: the prompt is the index, and no body appears" do
      prompt = Skills.system_prompt(agent(), [skill!(%{})], config: flag(true))

      refute prompt =~ @body_marker
      assert prompt =~ "load_skill"
    end

    test "OFF: the eager renderer is restored, bodies and all" do
      prompt = Skills.system_prompt(agent(), [skill!(%{})], config: flag(false))

      assert prompt =~ @body_marker
      refute prompt =~ "load_skill"
    end

    test "defaults ON now that load_skill exists (Step 5)" do
      prompt = Skills.system_prompt(agent(), [skill!(%{})])

      refute prompt =~ @body_marker
      assert prompt =~ "load_skill"
    end
  end

  defp flag(value) do
    FlagStub.put(value)
    FlagStub
  end

  defmodule FlagStub do
    @moduledoc false

    def put(value), do: Process.put(:skills_progressive_disclosure, value)

    def get(:zaq, :skills_progressive_disclosure, _default, _opts) do
      Process.get(:skills_progressive_disclosure)
    end

    def get(app, key, default, _opts), do: Application.get_env(app, key, default)
  end
end

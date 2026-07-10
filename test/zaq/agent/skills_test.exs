defmodule Zaq.Agent.SkillsTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.MCP
  alias Zaq.Agent.Skill
  alias Zaq.Agent.Skills

  defp create_skill!(attrs) do
    {:ok, skill} =
      %{body: "Instructions.", tool_keys: [], tags: []}
      |> Map.merge(attrs)
      |> Skills.create_skill()

    skill
  end

  defp mcp_endpoint!(attrs \\ %{}) do
    {:ok, endpoint} =
      %{
        name: "Skill MCP #{System.unique_integer([:positive])}",
        type: "remote",
        status: "enabled",
        timeout_ms: 5000,
        url: "http://localhost:8000/mcp"
      }
      |> Map.merge(attrs)
      |> MCP.create_mcp_endpoint()

    endpoint
  end

  describe "create_skill/1" do
    test "creates a skill with valid attrs" do
      assert {:ok, %Skill{} = skill} =
               Skills.create_skill(%{
                 name: "calculator",
                 body: "Use tools for math.",
                 tags: ["Math"]
               })

      assert skill.name == "calculator"
      assert skill.tags == ["math"]
      assert skill.active
    end

    test "returns changeset error for invalid attrs" do
      assert {:error, %Ecto.Changeset{} = changeset} = Skills.create_skill(%{name: "Bad Name"})
      assert %{body: ["can't be blank"]} = errors_on(changeset)
    end

    test "accepts an existing MCP endpoint id" do
      endpoint = mcp_endpoint!()

      assert {:ok, %Skill{} = skill} =
               Skills.create_skill(%{
                 name: "with-mcp",
                 body: "Uses an endpoint.",
                 enabled_mcp_endpoint_ids: [endpoint.id]
               })

      assert skill.enabled_mcp_endpoint_ids == [endpoint.id]
    end

    test "rejects a non-existent MCP endpoint id at save time" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Skills.create_skill(%{
                 name: "bad-mcp",
                 body: "Points at nothing.",
                 enabled_mcp_endpoint_ids: [999_999]
               })

      assert %{enabled_mcp_endpoint_ids: ["contains unknown MCP endpoint ids: 999999"]} =
               errors_on(changeset)
    end
  end

  describe "update_skill/2" do
    test "updates fields" do
      skill = create_skill!(%{name: "updatable"})

      assert {:ok, updated} = Skills.update_skill(skill, %{description: "new", tags: ["One"]})
      assert updated.description == "new"
      assert updated.tags == ["one"]
    end

    test "rejects invalid update" do
      skill = create_skill!(%{name: "stays-valid"})
      assert {:error, %Ecto.Changeset{}} = Skills.update_skill(skill, %{name: "NOPE"})
    end

    test "rejects a non-existent MCP endpoint id on update" do
      skill = create_skill!(%{name: "mcp-update"})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Skills.update_skill(skill, %{enabled_mcp_endpoint_ids: [999_999]})

      assert %{enabled_mcp_endpoint_ids: ["contains unknown MCP endpoint ids: 999999"]} =
               errors_on(changeset)
    end
  end

  describe "delete_skill/1" do
    test "deletes the record" do
      skill = create_skill!(%{name: "doomed"})
      assert {:ok, _} = Skills.delete_skill(skill)
      assert Skills.get_skill(skill.id) == nil
    end
  end

  describe "get_skill/1 and get_skill!/1" do
    test "fetches by integer and string id" do
      skill = create_skill!(%{name: "fetchable"})
      assert %Skill{name: "fetchable"} = Skills.get_skill(skill.id)
      assert %Skill{name: "fetchable"} = Skills.get_skill(to_string(skill.id))
      assert %Skill{name: "fetchable"} = Skills.get_skill!(skill.id)
    end

    test "get_skill/1 returns nil for unknown or malformed ids" do
      assert Skills.get_skill(0) == nil
      assert Skills.get_skill("not-an-id") == nil
    end

    test "get_skill!/1 raises on malformed id" do
      assert_raise ArgumentError, fn -> Skills.get_skill!("nope") end
    end
  end

  describe "list functions" do
    test "list_skills/0 returns all ordered by name" do
      create_skill!(%{name: "zebra"})
      create_skill!(%{name: "alpha"})

      assert ["alpha", "zebra"] = Skills.list_skills() |> Enum.map(& &1.name)
    end

    test "list_active_skills/0 excludes inactive skills" do
      create_skill!(%{name: "on"})
      create_skill!(%{name: "off", active: false})

      assert ["on"] = Skills.list_active_skills() |> Enum.map(& &1.name)
    end

    test "get_skills_by_ids/1 drops ghost ids and orders by name" do
      a = create_skill!(%{name: "b-skill"})
      b = create_skill!(%{name: "a-skill"})

      assert ["a-skill", "b-skill"] =
               Skills.get_skills_by_ids([a.id, b.id, 999_999]) |> Enum.map(& &1.name)

      assert Skills.get_skills_by_ids([]) == []
    end
  end

  describe "search_skills/1" do
    setup do
      create_skill!(%{name: "math-helper", tags: ["math", "utility"], description: "arithmetic"})
      create_skill!(%{name: "web-search", tags: ["web"], description: "browse pages"})
      create_skill!(%{name: "retired", tags: ["math"], active: false})
      :ok
    end

    test "matches any of the given tags" do
      assert ["math-helper", "retired"] =
               Skills.search_skills(%{tags: ["math"]}) |> Enum.map(& &1.name)

      assert ["math-helper", "retired", "web-search"] =
               Skills.search_skills(%{tags: ["math", "web"]}) |> Enum.map(& &1.name)
    end

    test "tag matching is case-insensitive on input" do
      assert ["math-helper", "retired"] =
               Skills.search_skills(%{tags: [" MATH "]}) |> Enum.map(& &1.name)
    end

    test "empty or blank tag lists do not filter" do
      assert length(Skills.search_skills(%{tags: []})) == 3
      assert length(Skills.search_skills(%{tags: ["", "  "]})) == 3
    end

    test "free text matches name and description case-insensitively" do
      assert ["web-search"] = Skills.search_skills(%{q: "WEB"}) |> Enum.map(& &1.name)
      assert ["math-helper"] = Skills.search_skills(%{q: "arithme"}) |> Enum.map(& &1.name)
    end

    test "free text treats LIKE wildcards literally" do
      assert Skills.search_skills(%{q: "%"}) == []
      assert Skills.search_skills(%{q: "_"}) == []
    end

    test "active filter combines with tags" do
      assert ["math-helper"] =
               Skills.search_skills(%{tags: ["math"], active: true}) |> Enum.map(& &1.name)

      assert ["retired"] =
               Skills.search_skills(%{tags: ["math"], active: false}) |> Enum.map(& &1.name)
    end

    test "empty filters return everything" do
      assert length(Skills.search_skills(%{})) == 3
    end
  end

  describe "change_skill/2" do
    test "returns a changeset" do
      skill = create_skill!(%{name: "changeable"})
      assert %Ecto.Changeset{} = Skills.change_skill(skill, %{description: "x"})
    end
  end

  describe "enabled_for_agent/1" do
    test "returns [] without hitting the database when there are no skill ids" do
      assert Skills.enabled_for_agent(%ConfiguredAgent{enabled_skill_ids: []}) == []
      assert Skills.enabled_for_agent(%ConfiguredAgent{enabled_skill_ids: nil}) == []
    end

    test "returns only active skills, dropping ghosts and inactive ones" do
      active = create_skill!(%{name: "active-skill"})
      inactive = create_skill!(%{name: "inactive-skill", active: false})

      agent = %ConfiguredAgent{enabled_skill_ids: [active.id, inactive.id, 999_999]}

      assert ["active-skill"] = Skills.enabled_for_agent(agent) |> Enum.map(& &1.name)
    end
  end

  describe "effective_tool_keys/2" do
    test "unions agent keys with skill keys, deduped" do
      skill = %Skill{tool_keys: ["data_source.get_document", "answering.search_knowledge_base"]}

      agent = %ConfiguredAgent{enabled_tool_keys: ["answering.search_knowledge_base"]}

      assert Skills.effective_tool_keys(agent, [skill]) == [
               "answering.search_knowledge_base",
               "data_source.get_document"
             ]
    end

    test "drops skill tool keys no longer present in the registry" do
      skill = %Skill{tool_keys: ["ghost.removed_tool", "data_source.get_document"]}
      agent = %ConfiguredAgent{enabled_tool_keys: []}

      assert Skills.effective_tool_keys(agent, [skill]) == ["data_source.get_document"]
    end

    test "passes agent's own keys through unfiltered" do
      agent = %ConfiguredAgent{enabled_tool_keys: ["files.missing"]}
      assert Skills.effective_tool_keys(agent, []) == ["files.missing"]
    end

    test "handles nil key lists" do
      agent = %ConfiguredAgent{enabled_tool_keys: nil}
      skill = %Skill{tool_keys: nil}
      assert Skills.effective_tool_keys(agent, [skill]) == []
    end
  end

  describe "effective_mcp_endpoint_ids/2" do
    test "unions agent endpoint ids with skill endpoint ids, deduped, agent first" do
      skill_a = %Skill{enabled_mcp_endpoint_ids: [2, 3]}
      skill_b = %Skill{enabled_mcp_endpoint_ids: [3, 4]}
      agent = %ConfiguredAgent{enabled_mcp_endpoint_ids: [1, 2]}

      assert Skills.effective_mcp_endpoint_ids(agent, [skill_a, skill_b]) == [1, 2, 3, 4]
    end

    test "returns the agent's own ids when there are no skills" do
      agent = %ConfiguredAgent{enabled_mcp_endpoint_ids: [7, 8]}
      assert Skills.effective_mcp_endpoint_ids(agent, []) == [7, 8]
    end

    test "handles nil id lists" do
      agent = %ConfiguredAgent{enabled_mcp_endpoint_ids: nil}
      skill = %Skill{enabled_mcp_endpoint_ids: nil}
      assert Skills.effective_mcp_endpoint_ids(agent, [skill]) == []
    end
  end

  describe "effective_system_prompt/2 and render_prompt_block/1" do
    test "returns the bare job when there are no skills" do
      agent = %ConfiguredAgent{job: "You are helpful."}
      assert Skills.effective_system_prompt(agent, []) == "You are helpful."
    end

    test "appends the rendered skills block to the job" do
      agent = %ConfiguredAgent{job: "You are helpful."}

      skill = %Skill{
        name: "calculator",
        description: "Precise arithmetic",
        body: "Always use tools for math."
      }

      prompt = Skills.effective_system_prompt(agent, [skill])

      assert prompt =~ "You are helpful.\n\nYou have access to the following skills:"
      assert prompt =~ "## calculator"
      assert prompt =~ "Precise arithmetic"
      assert prompt =~ "Always use tools for math."
    end

    test "returns just the skills block when the job is empty" do
      skill = %Skill{name: "solo", body: "Body only."}

      for agent <- [%ConfiguredAgent{job: nil}, %ConfiguredAgent{job: ""}] do
        prompt = Skills.effective_system_prompt(agent, [skill])
        assert String.starts_with?(prompt, "You have access to the following skills:")
        assert prompt =~ "## solo"
      end
    end

    test "render_prompt_block/1 returns nil for an empty list" do
      assert Skills.render_prompt_block([]) == nil
    end

    test "render_prompt_block/1 skips blank descriptions" do
      block = Skills.render_prompt_block([%Skill{name: "terse", description: nil, body: "B."}])
      assert block == "You have access to the following skills:\n\n## terse\n\nB."
    end

    test "render_prompt_block/1 renders multiple skills in order" do
      block =
        Skills.render_prompt_block([
          %Skill{name: "first", body: "One."},
          %Skill{name: "second", body: "Two."}
        ])

      {first_idx, _} = :binary.match(block, "## first")
      {second_idx, _} = :binary.match(block, "## second")
      assert first_idx < second_idx
    end
  end
end

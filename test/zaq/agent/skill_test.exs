defmodule Zaq.Agent.SkillTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Agent.Skill
  alias Zaq.Repo

  @valid_attrs %{
    name: "calculator",
    body: "# Calculator\nUse the arithmetic tools instead of mental math.",
    description: "Precise arithmetic via tools",
    tool_keys: ["answering.search_knowledge_base"],
    tags: ["math", "utility"]
  }

  describe "changeset/2 required fields" do
    test "valid with name and body only" do
      changeset = Skill.changeset(%Skill{}, %{name: "my-skill", body: "Do the thing."})
      assert changeset.valid?
    end

    test "requires name" do
      changeset = Skill.changeset(%Skill{}, Map.delete(@valid_attrs, :name))
      assert "can't be blank" in errors_on(changeset).name
    end

    test "requires body" do
      changeset = Skill.changeset(%Skill{}, Map.delete(@valid_attrs, :body))
      assert "can't be blank" in errors_on(changeset).body
    end
  end

  describe "changeset/2 name constraints" do
    test "accepts lowercase kebab-case names" do
      for name <- ["calc", "weather-advisor", "a1-b2-c3"] do
        changeset = Skill.changeset(%Skill{}, %{@valid_attrs | name: name})
        assert changeset.valid?, "expected #{name} to be valid"
      end
    end

    test "rejects names that are not lowercase kebab-case" do
      for name <- ["Calculator", "my_skill", "my skill", "-lead", "trail-", "a--b"] do
        changeset = Skill.changeset(%Skill{}, %{@valid_attrs | name: name})

        assert "must be lowercase kebab-case (letters, digits, hyphens)" in errors_on(changeset).name,
               "expected #{name} to be rejected"
      end
    end

    test "rejects names longer than 64 chars" do
      long_name = String.duplicate("a", 65)
      changeset = Skill.changeset(%Skill{}, %{@valid_attrs | name: long_name})
      assert "should be at most 64 character(s)" in errors_on(changeset).name
    end

    test "rejects single-character names" do
      changeset = Skill.changeset(%Skill{}, %{@valid_attrs | name: "a"})
      assert "should be at least 2 character(s)" in errors_on(changeset).name
    end

    test "enforces unique names at the database level" do
      assert {:ok, _} = %Skill{} |> Skill.changeset(@valid_attrs) |> Repo.insert()

      assert {:error, changeset} = %Skill{} |> Skill.changeset(@valid_attrs) |> Repo.insert()
      assert "has already been taken" in errors_on(changeset).name
    end
  end

  describe "changeset/2 description" do
    test "rejects descriptions longer than 1024 chars" do
      changeset =
        Skill.changeset(%Skill{}, %{@valid_attrs | description: String.duplicate("d", 1025)})

      assert "should be at most 1024 character(s)" in errors_on(changeset).description
    end
  end

  describe "changeset/2 tool_keys" do
    test "accepts known tool keys from the registry" do
      changeset =
        Skill.changeset(%Skill{}, %{
          @valid_attrs
          | tool_keys: ["answering.search_knowledge_base", "data_source.get_document"]
        })

      assert changeset.valid?
    end

    test "rejects unknown tool keys" do
      changeset = Skill.changeset(%Skill{}, %{@valid_attrs | tool_keys: ["nope.not_a_tool"]})
      assert "contains unknown tools: nope.not_a_tool" in errors_on(changeset).tool_keys
    end

    test "tolerates ghost keys already persisted on the record" do
      skill = %Skill{tool_keys: ["ghost.removed_tool"]}

      changeset =
        Skill.changeset(skill, %{
          name: "ghosted",
          body: "body",
          tool_keys: ["ghost.removed_tool", "answering.search_knowledge_base"]
        })

      assert changeset.valid?
    end

    test "still rejects new unknown keys alongside ghost keys" do
      skill = %Skill{tool_keys: ["ghost.removed_tool"]}

      changeset =
        Skill.changeset(skill, %{
          name: "ghosted",
          body: "body",
          tool_keys: ["ghost.removed_tool", "brand.new_unknown"]
        })

      assert "contains unknown tools: brand.new_unknown" in errors_on(changeset).tool_keys
    end
  end

  describe "changeset/2 enabled_mcp_endpoint_ids" do
    test "casts, dedupes, and keeps positive integer ids" do
      changeset =
        Skill.changeset(
          %Skill{},
          Map.put(@valid_attrs, :enabled_mcp_endpoint_ids, [2, 2, "3", 1])
        )

      assert changeset.valid?
      assert get_field(changeset, :enabled_mcp_endpoint_ids) == [2, 3, 1]
    end

    test "drops non-positive ids" do
      changeset =
        Skill.changeset(%Skill{}, Map.put(@valid_attrs, :enabled_mcp_endpoint_ids, [0, -1, 5]))

      assert get_field(changeset, :enabled_mcp_endpoint_ids) == [5]
    end

    test "defaults to empty list when absent and persists" do
      assert {:ok, skill} =
               %Skill{}
               |> Skill.changeset(Map.delete(@valid_attrs, :enabled_mcp_endpoint_ids))
               |> Repo.insert()

      assert skill.enabled_mcp_endpoint_ids == []
    end
  end

  describe "changeset/2 tag normalization" do
    test "downcases, trims, and dedupes tags" do
      changeset =
        Skill.changeset(%Skill{}, %{@valid_attrs | tags: [" Math ", "math", "UTILITY", ""]})

      assert get_field(changeset, :tags) == ["math", "utility"]
    end

    test "defaults to empty list when tags are absent" do
      changeset = Skill.changeset(%Skill{}, %{name: "no-tags", body: "body"})
      assert get_field(changeset, :tags) == []
    end
  end

  describe "defaults" do
    test "active defaults to true and persists" do
      assert {:ok, skill} = %Skill{} |> Skill.changeset(@valid_attrs) |> Repo.insert()
      assert skill.active
      assert skill.tags == ["math", "utility"]
    end
  end

  describe "tag normalization invariants" do
    property "tags are always trimmed, downcased, non-blank, and unique" do
      check all(tags <- list_of(string(:printable, max_length: 20), max_length: 10)) do
        changeset = Skill.changeset(%Skill{}, %{@valid_attrs | tags: tags})
        normalized = Ecto.Changeset.get_field(changeset, :tags)

        assert Enum.all?(normalized, fn tag ->
                 tag == tag |> String.trim() |> String.downcase() and tag != ""
               end)

        assert normalized == Enum.uniq(normalized)
      end
    end
  end
end

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
    test "valid with name, description and body only" do
      changeset =
        Skill.changeset(%Skill{}, %{
          name: "my-skill",
          description: "Does the thing. Use when the thing needs doing.",
          body: "Do the thing."
        })

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

    # The OAS spec requires `description`, and Jido's strict parse rejects a nil one. A
    # skill without one cannot become a %Spec{}, so it would be skipped at registration
    # and vanish from the index entirely — invisible to the model, with nothing raised.
    test "requires description — it is what the model reads in the prompt index" do
      changeset = Skill.changeset(%Skill{}, Map.delete(@valid_attrs, :description))
      assert "can't be blank" in errors_on(changeset).description
    end

    test "rejects a blank description" do
      changeset = Skill.changeset(%Skill{}, %{@valid_attrs | description: "   "})
      assert "can't be blank" in errors_on(changeset).description
    end
  end

  # Name/description shape is now validated by Jido's Loader (via Skills.Validation), not
  # by ZAQ-local regexes and length caps. The messages therefore come from Jido.
  describe "changeset/2 name constraints (owned by Jido's Loader)" do
    test "accepts lowercase kebab-case names" do
      for name <- ["calc", "weather-advisor", "a1-b2-c3"] do
        changeset = Skill.changeset(%Skill{}, %{@valid_attrs | name: name})
        assert changeset.valid?, "expected #{name} to be valid"
      end
    end

    test "accepts a single-character name — the OAS spec allows 1-64 chars" do
      changeset = Skill.changeset(%Skill{}, %{@valid_attrs | name: "a"})
      assert changeset.valid?
    end

    test "rejects names that are not lowercase kebab-case" do
      for name <- ["Calculator", "my_skill", "my skill", "-lead", "trail-", "a--b"] do
        changeset = Skill.changeset(%Skill{}, %{@valid_attrs | name: name})

        refute changeset.valid?, "expected #{name} to be rejected"
        assert Enum.any?(errors_on(changeset).name, &(&1 =~ "Invalid skill name"))
      end
    end

    test "rejects names longer than 64 chars — never persists a truncated one" do
      changeset = Skill.changeset(%Skill{}, %{@valid_attrs | name: String.duplicate("a", 65)})

      refute changeset.valid?
      assert errors_on(changeset).name != []
    end

    test "enforces unique names at the database level" do
      assert {:ok, _} = %Skill{} |> Skill.changeset(@valid_attrs) |> Repo.insert()

      assert {:error, changeset} = %Skill{} |> Skill.changeset(@valid_attrs) |> Repo.insert()
      assert "has already been taken" in errors_on(changeset).name
    end
  end

  # Jido TRUNCATES an over-long description and returns :ok even in strict mode (#323 G5).
  # ZAQ must reject instead — a silently-shortened record of truth is not acceptable.
  describe "changeset/2 truncation guard" do
    test "a 1024-char description is accepted (exactly at the cap)" do
      changeset =
        Skill.changeset(%Skill{}, %{@valid_attrs | description: String.duplicate("d", 1024)})

      assert changeset.valid?
    end

    test "a 1025-char description is REJECTED, never persisted truncated" do
      long = String.duplicate("d", 1025)

      assert {:error, changeset} =
               %Skill{} |> Skill.changeset(%{@valid_attrs | description: long}) |> Repo.insert()

      assert "is too long (max 1024 characters)" in errors_on(changeset).description
      assert Repo.aggregate(Skill, :count) == 0
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
          description: "A skill referencing a retired tool key.",
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
          description: "A skill referencing a retired tool key.",
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
      changeset =
        Skill.changeset(%Skill{}, %{name: "no-tags", description: "No tags here.", body: "body"})

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

  # `tool_keys` and `provided_tool_keys` hold the same value for the rollout window, so
  # a node still running the old code can keep reading `tool_keys`. These tests are the
  # contract for that window; they are deleted with the column.
  describe "changeset/2 tool_keys ↔ provided_tool_keys dual-write" do
    test "a write through the OLD field populates BOTH columns" do
      assert {:ok, skill} =
               %Skill{}
               |> Skill.changeset(%{@valid_attrs | tool_keys: ["data_source.get_document"]})
               |> Repo.insert()

      assert skill.tool_keys == ["data_source.get_document"]
      assert skill.provided_tool_keys == ["data_source.get_document"]
    end

    test "a write through the NEW field populates BOTH columns — old code still reads tool_keys" do
      attrs =
        @valid_attrs
        |> Map.delete(:tool_keys)
        |> Map.put(:provided_tool_keys, ["data_source.get_document"])

      assert {:ok, skill} = %Skill{} |> Skill.changeset(attrs) |> Repo.insert()

      assert skill.provided_tool_keys == ["data_source.get_document"]
      assert skill.tool_keys == ["data_source.get_document"]
    end

    test "provided_tool_keys wins when both are supplied — it is the field that survives" do
      attrs =
        @valid_attrs
        |> Map.put(:tool_keys, ["answering.search_knowledge_base"])
        |> Map.put(:provided_tool_keys, ["data_source.get_document"])

      changeset = Skill.changeset(%Skill{}, attrs)

      assert get_field(changeset, :provided_tool_keys) == ["data_source.get_document"]
      assert get_field(changeset, :tool_keys) == ["data_source.get_document"]
    end

    test "an unknown key written through the NEW field errors on that field" do
      attrs =
        @valid_attrs
        |> Map.delete(:tool_keys)
        |> Map.put(:provided_tool_keys, ["nope.not_a_tool"])

      changeset = Skill.changeset(%Skill{}, attrs)

      assert "contains unknown tools: nope.not_a_tool" in errors_on(changeset).provided_tool_keys
    end

    test "ghost keys persisted on either column are grandfathered" do
      skill = %Skill{
        provided_tool_keys: ["ghost.removed_tool"],
        tool_keys: ["ghost.removed_tool"]
      }

      changeset =
        Skill.changeset(skill, %{
          name: "ghosted",
          description: "A skill referencing a retired tool key.",
          body: "body",
          provided_tool_keys: ["ghost.removed_tool", "answering.search_knowledge_base"]
        })

      assert changeset.valid?
    end

    property "both columns always agree after a changeset" do
      check all(
              keys <-
                list_of(
                  member_of(["answering.search_knowledge_base", "data_source.get_document"]),
                  max_length: 4
                )
            ) do
        for field <- [:tool_keys, :provided_tool_keys] do
          changeset =
            Skill.changeset(
              %Skill{},
              @valid_attrs |> Map.delete(:tool_keys) |> Map.put(field, keys)
            )

          assert get_field(changeset, :tool_keys) == get_field(changeset, :provided_tool_keys)
        end
      end
    end
  end

  describe "changeset/2 allowed_tools (OAS — separate from provided_tool_keys)" do
    test "is not validated against the ZAQ tool registry — it is an OAS tool-name list" do
      changeset =
        Skill.changeset(%Skill{}, Map.put(@valid_attrs, :allowed_tools, ["Read", "Bash"]))

      assert changeset.valid?
      assert get_field(changeset, :allowed_tools) == ["Read", "Bash"]
    end

    test "trims, drops blanks, and dedupes" do
      changeset =
        Skill.changeset(
          %Skill{},
          Map.put(@valid_attrs, :allowed_tools, [" Read ", "Read", "", "Bash"])
        )

      assert get_field(changeset, :allowed_tools) == ["Read", "Bash"]
    end

    test "does not leak into provided_tool_keys, and vice versa" do
      attrs =
        @valid_attrs
        |> Map.put(:tool_keys, ["data_source.get_document"])
        |> Map.put(:allowed_tools, ["Read"])

      assert {:ok, skill} = %Skill{} |> Skill.changeset(attrs) |> Repo.insert()

      assert skill.allowed_tools == ["Read"]
      assert skill.provided_tool_keys == ["data_source.get_document"]
    end
  end

  # Pre-existing rows may carry a null or blank description — the column was nullable
  # before the OAS conformance fix. Such a row cannot become a %Spec{}, so it would be
  # skipped at registration and disappear from the index without raising. The backfill
  # migration rescues them; this asserts the schema can no longer create one.
  describe "legacy rows with no description" do
    test "cannot be created through the changeset any more" do
      assert {:error, changeset} =
               %Skill{}
               |> Skill.changeset(Map.delete(@valid_attrs, :description))
               |> Repo.insert()

      assert "can't be blank" in errors_on(changeset).description
    end

    test "a legacy null-description row is still editable — the fix is not a trap" do
      # Simulates a row that predates the requirement: written straight to the DB,
      # bypassing the changeset, exactly as the old code could have left it.
      {:ok, _} =
        Repo.query(
          """
          INSERT INTO agent_skills (name, description, body, tool_keys, provided_tool_keys,
                                    allowed_tools, enabled_mcp_endpoint_ids, tags, active,
                                    inserted_at, updated_at)
          VALUES ('legacy', NULL, 'body', '{}', '{}', '{}', '{}', '{}', true, NOW(), NOW())
          """,
          []
        )

      legacy = Repo.get_by!(Skill, name: "legacy")
      assert legacy.description == nil

      assert {:ok, fixed} =
               legacy
               |> Skill.changeset(%{description: "Backfilled by an operator."})
               |> Repo.update()

      assert fixed.description == "Backfilled by an operator."
    end
  end

  # Jido caps name/description/compatibility but not body. ZAQ caps it because a loaded
  # body stays in the agent's context for the server's life. Global write-time rails from
  # Zaq.Agent.Skills.Limits.
  describe "changeset/2 body size caps" do
    # ~1.3 tokens per whitespace-delimited word (TokenEstimator), so N words ≈ N*1.3 tokens
    # and byte size ≈ 5N. "w " repeated is a cheap knob for both.
    defp body_of_tokens(target_tokens) do
      words = ceil(target_tokens / 1.3)
      String.duplicate("w ", words)
    end

    test "a normal-sized body is accepted with no warning" do
      changeset = Skill.changeset(%Skill{}, %{@valid_attrs | body: "A few words of guidance."})

      assert changeset.valid?
      assert get_field(changeset, :diagnostics)["warning_count"] == 0
    end

    test "a body over the warning threshold saves, with a non-blocking warning" do
      changeset = Skill.changeset(%Skill{}, %{@valid_attrs | body: body_of_tokens(17_000)})

      assert changeset.valid?

      warnings = get_field(changeset, :diagnostics)["warnings"]
      assert Enum.any?(warnings, &(&1["type"] == "body_large"))
    end

    test "a body over the token cap is rejected" do
      changeset = Skill.changeset(%Skill{}, %{@valid_attrs | body: body_of_tokens(33_000)})

      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).body, &(&1 =~ "too long"))
    end

    test "a body over the byte cap is rejected even if the token estimate is under" do
      # No whitespace → TokenEstimator sees one giant word (~1 token), so only the byte
      # ceiling can catch this. 200KB of a single token exceeds the 128KB byte cap.
      changeset =
        Skill.changeset(%Skill{}, %{@valid_attrs | body: String.duplicate("x", 200_000)})

      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).body, &(&1 =~ "too large"))
    end
  end

  describe "new Spec-backing fields" do
    test "a record with no new fields set persists with inert defaults" do
      assert {:ok, skill} = %Skill{} |> Skill.changeset(@valid_attrs) |> Repo.insert()

      assert skill.allowed_tools == []
      assert skill.resource_root == nil
      # diagnostics is written by validation, string-keyed to match the stored/reloaded
      # shape, and a clean skill has none to report.
      assert %{"warning_count" => 0, "errors" => []} = skill.diagnostics
    end

    test "resource_root round-trips" do
      attrs = Map.put(@valid_attrs, :resource_root, "skills/calculator")

      assert {:ok, skill} = %Skill{} |> Skill.changeset(attrs) |> Repo.insert()
      assert skill.resource_root == "skills/calculator"
    end

    test "diagnostics is not user-settable — validation owns it" do
      attrs = Map.put(@valid_attrs, :diagnostics, %{"warnings" => ["spoofed"]})

      assert {:ok, skill} = %Skill{} |> Skill.changeset(attrs) |> Repo.insert()

      # The submitted value is discarded, not merged: diagnostics is a cache of what the
      # loader reported, and a user-supplied one would be a lie the BO then badges on.
      assert %{"warnings" => []} = skill.diagnostics
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

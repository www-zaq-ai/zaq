defmodule Zaq.Agent.Skills.ValidationTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Jido.AI.Skill.Loader
  alias Jido.AI.Skill.Spec
  alias Zaq.Agent.Skill
  alias Zaq.Agent.Skills.Validation
  alias Zaq.Repo

  @valid %{
    name: "calculator",
    description: "Precise arithmetic. Use when the user asks for a calculation.",
    body: "# Calculator\nUse the arithmetic tools instead of mental math.",
    allowed_tools: []
  }

  describe "round trip: attrs -> SKILL.md -> %Spec{}" do
    test "a valid skill round-trips field-for-field" do
      assert {:ok, %Spec{} = spec, _diagnostics} = Validation.validate(@valid)

      assert spec.name == @valid.name
      assert spec.description == @valid.description
      assert spec.body_ref == {:inline, @valid.body}
    end

    test "the serialized document is parseable SKILL.md" do
      content = Validation.to_skill_md(@valid.name, @valid.description, @valid.body)

      assert String.starts_with?(content, "---\n")
      assert {:ok, %Spec{}} = Loader.parse(content, "calculator/SKILL.md", lenient: false)
    end

    # The body is markdown and may legitimately contain a `---` horizontal rule. If that
    # were mistaken for the frontmatter delimiter, the body would be silently truncated.
    test "a body containing --- survives serialization intact" do
      body = "Intro paragraph.\n\n---\n\nSection after a horizontal rule.\n\n---\n\nAnd another."

      assert {:ok, %Spec{body_ref: {:inline, parsed}}, _} =
               Validation.validate(%{@valid | body: body})

      assert parsed == body
    end

    test "a description containing colons, quotes and hashes survives YAML encoding" do
      description = ~s(Handles "quoted" text: colons, # hashes, and 'apostrophes'.)

      assert {:ok, %Spec{} = spec, _} = Validation.validate(%{@valid | description: description})

      assert spec.description == description
    end
  end

  # The OAS spec encodes allowed-tools as a SPACE-SEPARATED STRING under a kebab-case key,
  # not a YAML list. Emitting a list parses fine in Jido but produces non-conformant
  # SKILL.md, which breaks export and catalog interop.
  describe "allowed-tools conformance" do
    test "is emitted as a kebab-cased key with a space-separated value" do
      content = Validation.to_skill_md("calculator", "d", "b", ["Read", "Bash"])

      assert content =~ ~s(allowed-tools: "Read Bash")
      refute content =~ "allowed_tools"
    end

    test "round-trips back to a list of tool names" do
      assert {:ok, %Spec{allowed_tools: tools}, _} =
               Validation.validate(%{@valid | allowed_tools: ["Read", "Bash"]})

      assert tools == ["Read", "Bash"]
    end

    test "is omitted entirely when empty — not emitted as an empty string" do
      refute Validation.to_skill_md("calculator", "d", "b", []) =~ "allowed-tools"
    end

    # A space-separated encoding cannot represent a tool name containing a space: it would
    # silently round-trip as two tools. The guard catches it rather than corrupting data.
    test "a tool name containing a space is REJECTED, not silently split" do
      assert {:error, errors} = Validation.validate(%{@valid | allowed_tools: ["Read File"]})

      assert {:allowed_tools, message} = List.keyfind(errors, :allowed_tools, 0)
      assert message =~ "must not contain spaces"
    end
  end

  # Jido warns when a skill's name does not match its parent directory. Parsing with
  # source_path "inline" makes Path.dirname/1 return ".", which never matches — so every
  # DB-backed skill would collect a bogus warning and be badged as broken in the BO.
  describe "diagnostics" do
    test "a clean skill produces NO warnings — in particular no directory_name_mismatch" do
      assert {:ok, _spec, diagnostics} = Validation.validate(@valid)

      # String-keyed to match the stored/reloaded shape (the :map column round-trips to
      # string keys), so ZAQ can merge its own warnings without mixing key types.
      assert diagnostics["warning_count"] == 0,
             "unexpected warnings: #{inspect(diagnostics["warnings"])}"

      refute Enum.any?(diagnostics["warnings"], &(&1["type"] == "directory_name_mismatch"))
    end

    test "diagnostics are persisted on the record so the BO need not re-parse" do
      assert {:ok, skill} = %Skill{} |> Skill.changeset(@valid) |> Repo.insert()

      # Reloaded, not the in-memory struct: this asserts the map actually survives the
      # JSON round trip through the :map column (atom keys go in, string keys come back).
      reloaded = Repo.get!(Skill, skill.id)

      assert %{"warning_count" => 0, "warnings" => []} = reloaded.diagnostics
    end
  end

  describe "errors map onto changeset fields" do
    test "an invalid name is sourced from Jido, not a ZAQ regex" do
      assert {:error, errors} = Validation.validate(%{@valid | name: "Not Kebab"})

      assert {:name, message} = List.keyfind(errors, :name, 0)
      assert message =~ "Invalid skill name"
    end

    test "an over-long description is rejected rather than truncated" do
      assert {:error, errors} =
               Validation.validate(%{@valid | description: String.duplicate("d", 1025)})

      assert {:description, message} = List.keyfind(errors, :description, 0)
      assert message =~ "too long"
    end
  end

  describe "resource_root" do
    test "accepts a relative path inside a volume" do
      changeset = Skill.changeset(%Skill{}, Map.put(@valid, :resource_root, "skills/calculator"))
      assert changeset.valid?
    end

    test "rejects an absolute path" do
      changeset = Skill.changeset(%Skill{}, Map.put(@valid, :resource_root, "/etc/passwd"))
      assert "must be relative to an ingestion volume" in errors_on(changeset).resource_root
    end

    test "rejects traversal out of the volume" do
      changeset = Skill.changeset(%Skill{}, Map.put(@valid, :resource_root, "skills/../../etc"))
      assert ~s(must not contain "..") in errors_on(changeset).resource_root
    end
  end

  property "validation never silently changes a field it accepts" do
    check all(
            description <- string(:alphanumeric, min_length: 1, max_length: 200),
            body <- string(:printable, min_length: 1, max_length: 300)
          ) do
      attrs = %{@valid | description: description, body: body}

      case Validation.validate(attrs) do
        {:ok, %Spec{} = spec, _diagnostics} ->
          # The whole point of the guard: what comes back is what went in.
          assert spec.description == description
          assert spec.body_ref == {:inline, body}

        {:error, _errors} ->
          :ok
      end
    end
  end
end

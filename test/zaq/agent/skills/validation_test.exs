defmodule Zaq.Agent.Skills.ValidationTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Jido.AI.Skill.Loader
  alias Jido.AI.Skill.Spec
  alias Zaq.Agent.Skill
  alias Zaq.Agent.Skills.Validation

  defmodule GenericFailure do
    defexception message: "generic parser failure"
  end

  defmodule GenericFailureLoader do
    def parse(_content, _source_path, _opts), do: {:error, %GenericFailure{}}
  end

  defmodule MetadataInvalidFieldLoader do
    def parse(_content, _source_path, _opts) do
      {:error,
       %Jido.AI.Skill.Error.Validation.InvalidField{
         field: :metadata,
         reason: :invalid_metadata,
         value: %{foo: :bar}
       }}
    end
  end

  defmodule TagsInvalidFieldLoader do
    def parse(_content, _source_path, _opts) do
      {:error,
       %Jido.AI.Skill.Error.Validation.InvalidField{
         field: :tags,
         reason: :invalid_type,
         value: ["tooling"]
       }}
    end
  end

  @valid %{
    name: "calculator",
    description: "Precise arithmetic. Use when the user asks for a calculation.",
    body: "# Calculator\nUse the arithmetic tools instead of mental math.",
    license: "Apache-2.0",
    compatibility: "Requires calculator tools.",
    metadata: %{"owner" => "ops", "tier" => "standard"},
    allowed_tools: []
  }

  describe "round trip: attrs -> SKILL.md -> %Spec{}" do
    test "a valid skill round-trips field-for-field" do
      assert {:ok, %Spec{} = spec} = Validation.validate(@valid)

      assert spec.name == @valid.name
      assert spec.description == @valid.description
      assert spec.body_ref == {:inline, @valid.body}
      assert spec.license == @valid.license
      assert spec.compatibility == @valid.compatibility
      assert spec.metadata == @valid.metadata
    end

    test "the serialized document is parseable SKILL.md" do
      content =
        Validation.to_skill_md(
          @valid.name,
          @valid.description,
          @valid.body,
          @valid.allowed_tools,
          @valid.license,
          @valid.compatibility,
          @valid.metadata
        )

      assert String.starts_with?(content, "---\n")
      assert content =~ ~s(license: "Apache-2.0")
      assert content =~ ~s(compatibility: "Requires calculator tools.")
      assert content =~ "metadata:\n  owner: \"ops\""
      assert {:ok, %Spec{} = spec} = Loader.parse(content, "calculator/SKILL.md", lenient: false)
      assert spec.metadata == @valid.metadata
    end

    test "serializer defaults are parseable and trailing fields stay absent" do
      content = Validation.to_skill_md(@valid.name, @valid.description, @valid.body)

      assert {:ok, %Spec{} = spec} = Loader.parse(content, "calculator/SKILL.md", lenient: false)
      assert spec.allowed_tools == []
      assert spec.license == nil
      assert spec.compatibility == nil
      assert spec.metadata == %{}

      assert {:ok, %Spec{} = spec} =
               Validation.to_skill_md(
                 @valid.name,
                 @valid.description,
                 @valid.body,
                 @valid.allowed_tools,
                 "MIT"
               )
               |> then(&Loader.parse(&1, "calculator/SKILL.md", lenient: false))

      assert spec.license == "MIT"
      assert spec.compatibility == nil
      assert spec.metadata == %{}

      assert {:ok, %Spec{} = spec} =
               Validation.to_skill_md(
                 @valid.name,
                 @valid.description,
                 @valid.body,
                 @valid.allowed_tools,
                 "BSD-3-Clause",
                 "Needs networking."
               )
               |> then(&Loader.parse(&1, "calculator/SKILL.md", lenient: false))

      assert spec.license == "BSD-3-Clause"
      assert spec.compatibility == "Needs networking."
      assert spec.metadata == %{}
    end

    test "optional fields are defensively serialized" do
      content =
        Validation.to_skill_md(
          @valid.name,
          @valid.description,
          @valid.body,
          @valid.allowed_tools,
          :invalid,
          "Requires networking.",
          %{}
        )

      refute content =~ "license:"
      assert content =~ ~s(compatibility: "Requires networking.")

      assert {:ok, %Spec{license: nil, compatibility: "Requires networking."}} =
               Loader.parse(content, "calculator/SKILL.md", lenient: false)
    end

    test "non-map metadata is omitted from serialization" do
      content =
        Validation.to_skill_md(
          @valid.name,
          @valid.description,
          @valid.body,
          @valid.allowed_tools,
          @valid.license,
          @valid.compatibility,
          :invalid
        )

      refute content =~ "metadata:"
      assert {:ok, %Spec{} = spec} = Loader.parse(content, "calculator/SKILL.md", lenient: false)
      assert spec.metadata == %{}
    end

    # The body is markdown and may legitimately contain a `---` horizontal rule. If that
    # were mistaken for the frontmatter delimiter, the body would be silently truncated.
    test "a body containing --- survives serialization intact" do
      body = "Intro paragraph.\n\n---\n\nSection after a horizontal rule.\n\n---\n\nAnd another."

      assert {:ok, %Spec{body_ref: {:inline, parsed}}} =
               Validation.validate(%{@valid | body: body})

      assert parsed == body
    end

    test "a description containing colons, quotes and hashes survives YAML encoding" do
      description = ~s(Handles "quoted" text: colons, # hashes, and 'apostrophes'.)

      assert {:ok, %Spec{} = spec} = Validation.validate(%{@valid | description: description})

      assert spec.description == description
    end
  end

  describe "manifest field conformance" do
    test "empty optional strings are omitted and round-trip as nil" do
      assert {:ok, %Spec{license: nil, compatibility: nil}} =
               Validation.validate(%{@valid | license: "", compatibility: ""})
    end

    test "rejects over-long compatibility through Jido validation" do
      assert {:error, errors} =
               Validation.validate(%{@valid | compatibility: String.duplicate("c", 501)})

      assert {:compatibility, message} = List.keyfind(errors, :compatibility, 0)
      assert message =~ "compatibility"
    end

    test "rejects metadata values that are not strings" do
      assert {:error, errors} = Validation.validate(%{@valid | metadata: %{"owner" => :ops}})

      assert {:metadata, "could not be encoded"} in errors
    end

    test "rejects metadata that is not a map" do
      assert {:error, errors} = Validation.validate(%{@valid | metadata: ["not", "a", "map"]})

      assert {:metadata, "could not be encoded"} in errors
    end

    test "rejects enumerable metadata structs" do
      assert {:error, errors} =
               Validation.validate(%{@valid | metadata: MapSet.new([{"owner", "ops"}])})

      assert {:metadata, "could not be encoded"} in errors
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
      assert {:ok, %Spec{allowed_tools: tools}} =
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
  # source_path "inline" makes Path.dirname/1 return ".", which never matches. DB-backed
  # skills must therefore use a source path matching the skill name even though ZAQ no
  # longer persists diagnostics.
  describe "loader source path" do
    test "a clean skill parses without directory_name_mismatch" do
      assert {:ok, %Spec{} = spec} = Validation.validate(@valid)

      warnings = spec.diagnostics.warnings || []
      refute Enum.any?(warnings, &(&1.type == :directory_name_mismatch))
    end
  end

  describe "errors map onto changeset fields" do
    test "non-skill-shaped attrs are rejected cleanly" do
      assert Validation.validate(%{}) == {:error, []}
      assert Validation.validate(%{name: "calculator", description: "d"}) == {:error, []}
    end

    test "a missing required description is mapped to that field" do
      assert {:error, errors} = Validation.validate(%{@valid | description: ""})

      assert {:description, "can't be blank"} in errors
    end

    test "an invalid name is sourced from Jido, not a ZAQ regex" do
      assert {:error, errors} = Validation.validate(%{@valid | name: "Not Kebab"})

      assert {:name, message} = List.keyfind(errors, :name, 0)
      assert message =~ "Invalid skill name"
    end

    test "invalid generated YAML is mapped onto the description field" do
      assert {:error, errors} = Validation.validate(%{@valid | name: "bad: name"})

      assert {:description, message} = List.keyfind(errors, :description, 0)
      assert message =~ "Invalid YAML"
    end

    test "generic parser errors are mapped onto the body field" do
      assert {:error, errors} = Validation.validate(@valid, loader: GenericFailureLoader)

      assert {:body, "generic parser failure"} in errors
    end

    test "a mapped InvalidField preserves its changeset field" do
      assert {:error, errors} =
               Validation.validate(@valid, loader: MetadataInvalidFieldLoader)

      assert {:metadata, message} = List.keyfind(errors, :metadata, 0)
      assert message =~ "Invalid metadata"
    end

    test "an unmapped InvalidField falls back to the body field" do
      assert {:error, errors} = Validation.validate(@valid, loader: TagsInvalidFieldLoader)

      assert {:body, message} = List.keyfind(errors, :body, 0)
      assert message =~ "Invalid tags"
    end

    test "an over-long name is rejected rather than truncated" do
      assert {:error, errors} =
               Validation.validate(%{@valid | name: String.duplicate("a", 65)})

      assert {:name, message} = List.keyfind(errors, :name, 0)
      assert message =~ "must be 1-64 chars"
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
      assert "must be relative to a storage volume" in errors_on(changeset).resource_root
    end

    test "rejects traversal out of the volume" do
      changeset = Skill.changeset(%Skill{}, Map.put(@valid, :resource_root, "skills/../../etc"))
      assert ~s(must not contain "..") in errors_on(changeset).resource_root
    end
  end

  property "validation never silently changes a field it accepts" do
    check all(
            description <- string(:alphanumeric, min_length: 1, max_length: 200),
            body <- string(:printable, min_length: 1, max_length: 300),
            license <- string(:alphanumeric, min_length: 1, max_length: 50),
            compatibility <- string(:alphanumeric, min_length: 1, max_length: 200)
          ) do
      attrs = %{
        @valid
        | description: description,
          body: body,
          license: license,
          compatibility: compatibility
      }

      case Validation.validate(attrs) do
        {:ok, %Spec{} = spec} ->
          # The whole point of the guard: what comes back is what went in.
          assert spec.description == description
          assert spec.body_ref == {:inline, body}
          assert spec.license == license
          assert spec.compatibility == compatibility

        {:error, _errors} ->
          :ok
      end
    end
  end
end

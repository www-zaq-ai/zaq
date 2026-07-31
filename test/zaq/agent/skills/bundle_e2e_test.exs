defmodule Zaq.Agent.Skills.BundleE2ETest do
  @moduledoc """
  The whole path, unstubbed: tool → `NodeRouter.dispatch/1` → `Ingestion.Api` → façade →
  `ResourceBundle` → `Jido.AI.Skill.Resources` → real files on a real volume.

  Every other test in this feature stubs one side or the other. This one stubs nothing,
  because the failure it exists to catch — the agent side and the ingestion side agreeing on
  a response shape — is invisible to both halves tested separately.
  """
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.Skills
  alias Zaq.Agent.Tools.Skills.LoadSkill
  alias Zaq.Agent.Tools.Skills.LoadSkillReference
  alias Zaq.Contracts.Materialization
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.RecordPage
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.Records.Content
  alias Zaq.Records.Materializer

  @test_base "test/tmp/bundle_e2e"
  @locator ".agents/skills/pricing-faq"

  setup do
    File.rm_rf!(@test_base)
    library = Path.join(@test_base, "library")
    archive = Path.join(@test_base, "archive")
    File.mkdir_p!(library)
    File.mkdir_p!(archive)

    original = Application.get_env(:zaq, Zaq.Ingestion)

    Application.put_env(:zaq, Zaq.Ingestion,
      base_path: @test_base,
      volumes: %{"library" => library, "archive" => archive}
    )

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.Ingestion, original || [])
      File.rm_rf!(@test_base)
    end)

    %{library: library, archive: archive}
  end

  defp write!(volume_root, relative, content) do
    path = Path.join([volume_root, @locator, relative])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  defp agent_with_skill!(skill_attrs \\ %{}) do
    {:ok, skill} =
      %{
        name: "pricing-faq",
        description: "Answers pricing questions.",
        body: "# Pricing FAQ\nConsult references/pricing-2026.md before quoting.",
        resource_root: @locator,
        tags: []
      }
      |> Map.merge(skill_attrs)
      |> Skills.create_skill()

    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, agent} =
      Agent.create_agent(%{
        name: "assistant-#{System.unique_integer([:positive])}",
        job: "Help.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        active: true,
        enabled_tool_keys: [],
        enabled_skill_ids: [skill.id]
      })

    {skill, agent, %{configured_agent_id: agent.id}}
  end

  describe "the full three-level disclosure, unstubbed" do
    test "level 2 lists real files, level 3 returns one's real content", %{library: library} do
      write!(library, "references/pricing-2026.md", "# Pricing 2026\nEnterprise: contact sales.")
      write!(library, "references/discounts.md", "Volume discounts start at 50 seats.")

      {_skill, _agent, context} = agent_with_skill!()

      # Level 2 — the manifest, metadata only.
      assert {:ok, loaded} = LoadSkill.run(%{name: "pricing-faq"}, context)
      assert loaded.instructions =~ "Consult references/pricing-2026.md"

      paths = Enum.map(loaded.resources, & &1.resource_path) |> Enum.sort()
      assert paths == ["references/discounts.md", "references/pricing-2026.md"]

      entry = Enum.find(loaded.resources, &(&1.resource_path == "references/pricing-2026.md"))
      assert entry.size == byte_size("# Pricing 2026\nEnterprise: contact sales.")

      # No content, and nothing about where the bytes live.
      refute inspect(loaded.resources) =~ "Enterprise"
      refute inspect(loaded.resources) =~ "library"
      refute inspect(loaded.resources) =~ Path.expand(@test_base)

      # Level 3 — the model echoes a path from the manifest and gets that file.
      assert {:ok, read} =
               LoadSkillReference.run(
                 %{skill_name: "pricing-faq", resource_path: entry.resource_path},
                 context
               )

      assert read.content == "# Pricing 2026\nEnterprise: contact sales."
    end

    test "a bundle on the second volume is reached without anyone naming it", %{archive: archive} do
      # `archive` sorts before `library`, so this also pins that resolution is by content,
      # not by luck of ordering.
      write!(archive, "references/old-prices.md", "2024 rates")

      {_skill, _agent, context} = agent_with_skill!()

      assert {:ok, loaded} = LoadSkill.run(%{name: "pricing-faq"}, context)
      assert [%{resource_path: "references/old-prices.md"}] = loaded.resources

      assert {:ok, read} =
               LoadSkillReference.run(
                 %{skill_name: "pricing-faq", resource_path: "references/old-prices.md"},
                 context
               )

      assert read.content == "2024 rates"
    end

    test "a renamed skill still reaches files uploaded under its old name", %{library: library} do
      write!(library, "references/pricing-2026.md", "sticky root works")

      # The skill was renamed; `resource_root` stayed put, which is the whole point of it
      # being sticky. A name-derived path would look under .agents/skills/renamed-faq.
      {_skill, _agent, context} = agent_with_skill!(%{name: "renamed-faq"})

      assert {:ok, loaded} = LoadSkill.run(%{name: "renamed-faq"}, context)
      assert [%{resource_path: "references/pricing-2026.md"}] = loaded.resources

      assert {:ok, read} =
               LoadSkillReference.run(
                 %{skill_name: "renamed-faq", resource_path: "references/pricing-2026.md"},
                 context
               )

      assert read.content == "sticky root works"
    end

    test "a binary asset lists but refuses to read as text", %{library: library} do
      write!(library, "assets/logo.png", <<137, 80, 78, 71, 0xFF, 0xFE>>)

      {_skill, _agent, context} = agent_with_skill!()

      assert {:ok, loaded} = LoadSkill.run(%{name: "pricing-faq"}, context)
      assert [%{resource_path: "assets/logo.png", size: 6}] = loaded.resources

      assert {:error, message} =
               LoadSkillReference.run(
                 %{skill_name: "pricing-faq", resource_path: "assets/logo.png"},
                 context
               )

      assert message =~ "binary file"
    end

    test "a scripts/ file is listed but never readable", %{library: library} do
      write!(library, "scripts/deploy.sh", "#!/bin/sh\nrm -rf /")

      {_skill, _agent, context} = agent_with_skill!()

      assert {:ok, loaded} = LoadSkill.run(%{name: "pricing-faq"}, context)
      assert [%{resource_path: "scripts/deploy.sh"}] = loaded.resources

      assert {:error, message} =
               LoadSkillReference.run(
                 %{skill_name: "pricing-faq", resource_path: "scripts/deploy.sh"},
                 context
               )

      assert message =~ "Scripts are not readable"
      refute message =~ "rm -rf"
    end

    test "traversal is refused across the real boundary, not just in unit tests" do
      {_skill, _agent, context} = agent_with_skill!()

      for path <- ["../../../etc/passwd", "/etc/passwd", "references/../../../etc/passwd"] do
        assert {:error, message} =
                 LoadSkillReference.run(
                   %{skill_name: "pricing-faq", resource_path: path},
                   context
                 )

        refute message =~ "root:"
      end
    end

    test "a skill with no uploads yields an empty manifest, not an error" do
      {_skill, _agent, context} = agent_with_skill!()

      assert {:ok, loaded} = LoadSkill.run(%{name: "pricing-faq"}, context)
      assert loaded.resources == []
      assert loaded.instructions =~ "Pricing FAQ"
    end

    test "an unattached agent cannot read another skill's real file", %{library: library} do
      write!(library, "references/pricing-2026.md", "CONFIDENTIAL RATES")

      {_skill, _agent, _context} = agent_with_skill!()

      credential =
        ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

      {:ok, outsider} =
        Agent.create_agent(%{
          name: "outsider-#{System.unique_integer([:positive])}",
          job: "Help.",
          model: "gpt-4.1-mini",
          credential_id: credential.id,
          strategy: "react",
          active: true,
          enabled_tool_keys: [],
          enabled_skill_ids: []
        })

      assert {:error, message} =
               LoadSkillReference.run(
                 %{skill_name: "pricing-faq", resource_path: "references/pricing-2026.md"},
                 %{configured_agent_id: outsider.id}
               )

      refute message =~ "CONFIDENTIAL"
    end
  end

  describe "records cross the boundary and materialize back, unstubbed" do
    test "listing yields records that carry a descriptor, not content", %{library: library} do
      write!(library, "references/pricing-2026.md", "# Pricing 2026\nEnterprise: contact sales.")

      assert [%Record{} = record] = list_records()

      # A handle: identity and metadata, no bytes.
      assert record.name == "pricing-2026.md"
      assert record.path == "references/pricing-2026.md"
      assert record.mime_type == "text/markdown"
      assert record.size == byte_size("# Pricing 2026\nEnterprise: contact sales.")
      assert record.content == nil

      # And it knows where its bytes live, without anyone else being told.
      assert %Materialization{role: :ingestion} = record.materialization
      assert record.materialization.params == %{locator: @locator}
    end

    test "a record materializes to its real file's content", %{library: library} do
      write!(library, "references/pricing-2026.md", "# Pricing 2026\nEnterprise: contact sales.")

      [record] = list_records()

      # The caller names no role, no action, no path — only the record it was handed.
      assert {:ok, materialized} = Materializer.materialize(record)

      assert materialized.content == "# Pricing 2026\nEnterprise: contact sales."
      assert materialized.attributes["encoding"] == "utf8"
    end

    test "a binary asset materializes as base64 and decodes to the exact bytes on disk", %{
      library: library
    } do
      png = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0xFE, 0x00, 0x01>>
      write!(library, "assets/logo.png", png)

      assert [record] = list_records(:assets)
      assert record.mime_type == "image/png"

      assert {:ok, materialized} = Materializer.materialize(record)
      assert materialized.attributes["encoding"] == "base64"
      assert {:ok, ^png} = Content.decode(materialized)

      # Raw bytes on both sides of the hop, so a cap means the same number either side.
      assert materialized.size == byte_size(png)
      assert byte_size(materialized.content) > byte_size(png)
    end

    test "a text-only caller refuses the same binary rather than receiving base64", %{
      library: library
    } do
      write!(library, "assets/logo.png", <<0x89, 0x50, 0x4E, 0x47, 0xFF, 0xFE>>)

      [record] = list_records(:assets)

      assert {:error, :invalid_utf8} = Materializer.materialize(record, as: :text)
    end

    test "an oversize file is refused before its bytes cross", %{library: library} do
      write!(library, "references/pricing-2026.md", String.duplicate("x", 5_000))

      [record] = list_records()

      assert {:error, {:too_large, 5_000}} = Materializer.materialize(record, max_bytes: 100)
    end

    test "nothing a record carries discloses the filesystem to a model", %{library: library} do
      write!(library, "references/pricing-2026.md", "rates")

      [record] = list_records()
      encoded = Jason.encode!(record)

      # The descriptor holds the locator, and the descriptor is not serialized. This is the
      # property the whole design rests on, asserted across the real boundary rather than
      # against a hand-built struct.
      refute encoded =~ @locator
      refute encoded =~ "materialization"
      refute encoded =~ "library"
      refute encoded =~ Path.expand(@test_base)
      refute record.id =~ @locator
    end
  end

  # The real listing action over the real router — the same call the agent's `Bundle` makes.
  # The page is one flat list, so the type filter is a prefix match on each record's path;
  # that the prefix is the only place type lives is the point of the shape.
  defp list_records(type \\ :references) do
    %{bundle: @locator}
    |> Event.new(:ingestion, opts: [action: :list_skill_bundle])
    |> NodeRouter.dispatch()
    |> Map.fetch!(:response)
    |> then(fn {:ok, %RecordPage{records: records}} ->
      Enum.filter(records, &String.starts_with?(&1.path, "#{type}/"))
    end)
  end
end

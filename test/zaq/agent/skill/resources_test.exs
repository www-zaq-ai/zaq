defmodule Zaq.Agent.Skill.ResourcesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Agent.Skill
  alias Zaq.Agent.Skill.Resources
  alias Zaq.Contracts.RecordPage

  defp skill(attrs), do: struct(%Skill{name: "calculator"}, attrs)

  describe "slug/1" do
    test "passes a spec-valid kebab-case name through untouched" do
      # Jido enforces ~r/^[a-z0-9]+(-[a-z0-9]+)*$/ on `name`, so this is the common case.
      assert Resources.slug("pricing-faq") == "pricing-faq"
      assert Resources.slug("calc2") == "calc2"
    end

    test "normalises names the spec would have rejected" do
      assert Resources.slug("Pricing FAQ") == "pricing-faq"
      assert Resources.slug("Weekly  Report!!") == "weekly-report"
      assert Resources.slug("--leading--and--trailing--") == "leading-and-trailing"
      assert Resources.slug("Ünïcode Ñame") == "unicode-name"
    end

    test "falls back to a placeholder when nothing survives normalisation" do
      assert Resources.slug("///") == "skill"
      assert Resources.slug("") == "skill"
      assert Resources.slug(nil) == "skill"
    end
  end

  describe "references/1" do
    test "returns the entries in the references bucket" do
      entry = Resources.entry("42", "prices.md", "disk")
      s = skill(%{resources: %{"references" => [entry]}})

      assert Resources.references(s) == [entry]
    end

    test "returns [] when the skill has no resources" do
      assert Resources.references(skill(%{resources: %{}})) == []
      assert Resources.references(skill(%{resources: nil})) == []
    end

    test "returns [] when another bucket is populated" do
      assert Resources.references(skill(%{resources: %{"scripts" => [%{}]}})) == []
    end
  end

  describe "add_references/2 and remove_reference/2" do
    test "appends to an empty skill" do
      entry = Resources.entry("42", "prices.md", "disk")

      assert Resources.add_references(skill(%{resources: %{}}), [entry]) ==
               %{"references" => [entry]}
    end

    test "appends without dropping existing entries or other buckets" do
      first = Resources.entry("1", "a.md", "disk")
      second = Resources.entry("2", "b.md", "disk")
      s = skill(%{resources: %{"references" => [first], "scripts" => []}})

      assert Resources.add_references(s, [second]) ==
               %{"references" => [first, second], "scripts" => []}
    end

    test "removes only the entry naming the file_id" do
      first = Resources.entry("1", "a.md", "disk")
      second = Resources.entry("2", "b.md", "disk")
      s = skill(%{resources: %{"references" => [first, second]}})

      assert Resources.remove_reference(s, "1") == %{"references" => [second]}
    end

    test "removing an absent file_id is a no-op" do
      entry = Resources.entry("1", "a.md", "disk")
      s = skill(%{resources: %{"references" => [entry]}})

      assert Resources.remove_reference(s, "999") == %{"references" => [entry]}
    end
  end

  describe "entry/3" do
    test "stringifies a numeric document id" do
      assert Resources.entry(42, "a.md", "disk")["file_id"] == "42"
    end
  end

  describe "record_page/1" do
    test "maps each reference to an unmaterialized record" do
      s =
        skill(%{
          resources: %{
            "references" => [
              Resources.entry("42", "prices.md", "disk"),
              Resources.entry("43", "chart.png", "gdrive")
            ]
          }
        })

      assert %RecordPage{resource_type: :item, records: [first, second]} =
               Resources.record_page(s)

      assert first.id == "42"
      assert first.name == "prices.md"
      assert first.kind == :file
      assert first.mime_type == "text/markdown"
      assert first.attributes == %{"provider" => "disk"}
      assert second.attributes == %{"provider" => "gdrive"}
      assert second.mime_type == "image/png"
    end

    test "never carries content or a materializing event" do
      s = skill(%{resources: %{"references" => [Resources.entry("1", "a.md", "disk")]}})

      assert %RecordPage{records: [record]} = Resources.record_page(s)
      assert record.content == nil
      assert record.materializing_event == nil
    end

    test "counts what it returned" do
      s = skill(%{resources: %{"references" => [Resources.entry("1", "a.md", "disk")]}})

      assert %RecordPage{stats: %{scanned: 1, returned: 1}} = Resources.record_page(s)
    end

    test "is empty for a skill with no references" do
      assert %RecordPage{records: [], stats: %{returned: 0}} =
               Resources.record_page(skill(%{resources: %{}}))

      assert %RecordPage{records: []} =
               Resources.record_page(skill(%{resources: %{"scripts" => []}}))
    end
  end

  describe "references_dir/1" do
    test "derives the directory from the skill name" do
      assert Resources.references_dir(skill(%{name: "pricing-faq"})) ==
               ".agents/skills/pricing-faq/references"
    end

    test "follows a rename" do
      assert Resources.references_dir(skill(%{name: "new-name"})) ==
               ".agents/skills/new-name/references"
    end

    test "normalises a name the spec would have rejected" do
      assert Resources.references_dir(skill(%{name: "Pricing FAQ"})) ==
               ".agents/skills/pricing-faq/references"
    end
  end

  describe "destination/2" do
    test "places the file inside the references dir" do
      assert Resources.destination(skill(%{name: "pricing-faq"}), "prices.pdf") ==
               ".agents/skills/pricing-faq/references/prices.pdf"
    end

    test "strips directory components from the client filename" do
      assert Resources.destination(skill(%{name: "s"}), "a/b/c.md") ==
               ".agents/skills/s/references/c.md"
    end

    test "refuses to escape via traversal segments" do
      assert Resources.destination(skill(%{name: "s"}), "../../etc/passwd") ==
               ".agents/skills/s/references/passwd"
    end

    test "refuses an absolute client path" do
      assert Resources.destination(skill(%{name: "s"}), "/etc/passwd") ==
               ".agents/skills/s/references/passwd"
    end

    test "falls back to a placeholder filename when nothing usable remains" do
      assert Resources.destination(skill(%{name: "s"}), "..") ==
               ".agents/skills/s/references/file"

      assert Resources.destination(skill(%{name: "s"}), "/") ==
               ".agents/skills/s/references/file"
    end

    test "preserves spaces and case in the filename itself" do
      assert Resources.destination(skill(%{name: "s"}), "Q3 Report.pdf") ==
               ".agents/skills/s/references/Q3 Report.pdf"
    end
  end

  describe "destination/2 containment (property)" do
    property "never escapes .agents/skills/ regardless of skill name and filename" do
      check all(
              name <- string(:printable, max_length: 40),
              filename <- string(:printable, max_length: 40),
              max_runs: 300
            ) do
        dest = Resources.destination(skill(%{name: name}), filename)

        assert String.starts_with?(dest, ".agents/skills/")
        refute ".." in Path.split(dest)
        refute String.starts_with?(dest, "/")
        # exactly: .agents, skills, <slug>, references, <file>
        assert length(Path.split(dest)) == 5
      end
    end
  end
end

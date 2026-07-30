defmodule Zaq.Agent.Skill.ResourcesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Agent.Skill
  alias Zaq.Agent.Skill.Resources

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

  describe "default_root/1" do
    test "derives the root from the skill name" do
      assert Resources.default_root(skill(%{name: "pricing-faq"})) == ".agents/skills/pricing-faq"
    end

    test "ignores any stored resource_root" do
      s = skill(%{name: "pricing-faq", resource_root: ".agents/skills/old-name"})
      assert Resources.default_root(s) == ".agents/skills/pricing-faq"
    end
  end

  describe "root/1" do
    test "derives from the name when no resource_root is stored" do
      assert Resources.root(skill(%{name: "pricing-faq"})) == ".agents/skills/pricing-faq"
    end

    test "prefers a stored resource_root" do
      s = skill(%{name: "new-name", resource_root: ".agents/skills/old-name"})
      assert Resources.root(s) == ".agents/skills/old-name"
    end

    test "ignores an unsafe stored root" do
      assert Resources.root(skill(%{name: "s", resource_root: "/etc"})) == ".agents/skills/s"
      assert Resources.root(skill(%{name: "s", resource_root: "../escape"})) == ".agents/skills/s"
    end

    test "is the parent of references_dir/1" do
      # Deleting a skill removes `root/1`; `references_dir/1` is only one child of it.
      s = skill(%{name: "pricing-faq"})
      assert Resources.references_dir(s) == Path.join(Resources.root(s), "references")
    end
  end

  describe "references_dir/1" do
    test "uses the default root when resource_root is nil" do
      assert Resources.references_dir(skill(%{name: "pricing-faq"})) ==
               ".agents/skills/pricing-faq/references"
    end

    test "uses the default root when resource_root is empty" do
      assert Resources.references_dir(skill(%{name: "pricing-faq", resource_root: ""})) ==
               ".agents/skills/pricing-faq/references"
    end

    test "reuses a stored resource_root verbatim, even after a rename" do
      # The skill was renamed but its files still live under the original root.
      s = skill(%{name: "new-name", resource_root: ".agents/skills/old-name"})
      assert Resources.references_dir(s) == ".agents/skills/old-name/references"
    end

    test "normalises a trailing slash on the stored root" do
      s = skill(%{name: "x", resource_root: ".agents/skills/old-name/"})
      assert Resources.references_dir(s) == ".agents/skills/old-name/references"
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
      # Only the *path shape* is sanitised — the filename is the operator's to choose,
      # and the ingestion browser displays it verbatim.
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

    property "a stored resource_root still cannot escape" do
      check all(
              root <- string(:printable, max_length: 40),
              filename <- string(:printable, max_length: 40),
              max_runs: 300
            ) do
        dest = Resources.destination(skill(%{name: "s", resource_root: root}), filename)

        refute ".." in Path.split(dest)
        refute String.starts_with?(dest, "/")
      end
    end
  end
end

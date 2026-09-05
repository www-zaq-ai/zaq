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
      assert Resources.default_root(skill(%{name: "pricing-faq"})) == "pricing-faq"
    end

    test "ignores any stored resource_root" do
      s = skill(%{name: "pricing-faq", resource_root: "old-name"})
      assert Resources.default_root(s) == "pricing-faq"
    end
  end

  describe "root/1" do
    test "derives from the name when no resource_root is stored" do
      assert Resources.root(skill(%{name: "pricing-faq"})) == "pricing-faq"
    end

    test "prefers a stored resource_root" do
      s = skill(%{name: "new-name", resource_root: "old-name"})
      assert Resources.root(s) == "old-name"
    end

    test "ignores an unsafe stored root" do
      assert Resources.root(skill(%{name: "s", resource_root: "/etc"})) == "s"
      assert Resources.root(skill(%{name: "s", resource_root: "../escape"})) == "s"
    end

    test "is the parent of references_dir/1" do
      s = skill(%{name: "pricing-faq"})
      assert Resources.references_dir(s) == Resources.root(s)
    end
  end

  describe "references_dir/1" do
    test "uses the default root when resource_root is nil" do
      assert Resources.references_dir(skill(%{name: "pricing-faq"})) ==
               "pricing-faq"
    end

    test "uses the default root when resource_root is empty" do
      assert Resources.references_dir(skill(%{name: "pricing-faq", resource_root: ""})) ==
               "pricing-faq"
    end

    test "reuses a stored resource_root verbatim, even after a rename" do
      # The skill was renamed but its files still live under the original root.
      s = skill(%{name: "new-name", resource_root: "old-name"})
      assert Resources.references_dir(s) == "old-name"
    end

    test "normalises a trailing slash on the stored root" do
      s = skill(%{name: "x", resource_root: "old-name/"})
      assert Resources.references_dir(s) == "old-name"
    end
  end

  describe "destination/2" do
    test "places the file inside the skill root" do
      assert Resources.destination(skill(%{name: "pricing-faq"}), "prices.pdf") ==
               "pricing-faq/prices.pdf"
    end

    test "strips directory components from the client filename" do
      assert Resources.destination(skill(%{name: "s"}), "a/b/c.md") ==
               "s/c.md"
    end

    test "refuses to escape via traversal segments" do
      assert Resources.destination(skill(%{name: "s"}), "../../etc/passwd") ==
               "s/passwd"
    end

    test "refuses an absolute client path" do
      assert Resources.destination(skill(%{name: "s"}), "/etc/passwd") ==
               "s/passwd"
    end

    test "falls back to a placeholder filename when nothing usable remains" do
      assert Resources.destination(skill(%{name: "s"}), "..") ==
               "s/file"

      assert Resources.destination(skill(%{name: "s"}), "/") ==
               "s/file"
    end

    test "uses the placeholder for non-binary filenames without losing the resource root" do
      default_skill = skill(%{name: "pricing-faq"})
      pinned_skill = skill(%{name: "renamed", resource_root: "original/resources"})

      for filename <- [
            nil,
            false,
            :missing,
            42,
            1.5,
            [],
            ~c"report.pdf",
            %{},
            {:filename, "report.pdf"},
            <<1::1>>
          ] do
        assert Resources.destination(default_skill, filename) == "pricing-faq/file",
               "expected placeholder for #{inspect(filename)}"

        assert Resources.destination(pinned_skill, filename) == "original/resources/file",
               "expected placeholder with preserved root for #{inspect(filename)}"
      end
    end

    test "preserves spaces and case in the filename itself" do
      # Only the *path shape* is sanitised — the filename is the operator's to choose,
      # and the storage browser displays it verbatim.
      assert Resources.destination(skill(%{name: "s"}), "Q3 Report.pdf") ==
               "s/Q3 Report.pdf"
    end
  end

  describe "destination/2 containment (property)" do
    property "never escapes the skill root regardless of skill name and filename" do
      check all(
              name <- string(:printable, max_length: 40),
              filename <- string(:printable, max_length: 40),
              max_runs: 300
            ) do
        dest = Resources.destination(skill(%{name: name}), filename)

        refute ".." in Path.split(dest)
        refute String.starts_with?(dest, "/")
        assert length(Path.split(dest)) == 2
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

    property "non-binary filenames always become the placeholder" do
      check all(
              filename <-
                one_of([
                  constant(nil),
                  boolean(),
                  integer(),
                  list_of(integer(), max_length: 8),
                  map_of(integer(), integer(), max_length: 8),
                  tuple({integer(), integer()}),
                  constant(<<1::1>>)
                ]),
              max_runs: 100
            ) do
        assert Resources.destination(
                 skill(%{name: "s", resource_root: "original/resources"}),
                 filename
               ) ==
                 "original/resources/file"
      end
    end
  end

  describe "resource type normalization" do
    test "defaults unsupported or missing values to reference" do
      assert Resources.normalize_resource_type("asset") == "asset"
      assert Resources.normalize_resource_type("nope") == "reference"
      assert Resources.normalize_resource_type(nil) == "reference"
    end
  end
end

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

  describe "references/1" do
    test "is empty for a skill with no resources" do
      assert Resources.references(skill(%{})) == []
      assert Resources.references(skill(%{resources: nil})) == []
      assert Resources.references(skill(%{resources: %{}})) == []
    end

    test "returns the stored references" do
      refs = [%{"file_id" => "1", "provider" => "disk"}]

      assert Resources.references(skill(%{resources: %{"references" => refs}})) == refs
    end
  end

  describe "add_reference/3" do
    test "appends to an empty skill" do
      assert Resources.add_reference(skill(%{}), "42", "disk") ==
               %{"references" => [%{"file_id" => "42", "provider" => "disk"}]}
    end

    test "stringifies an integer file_id" do
      assert %{"references" => [%{"file_id" => "42"}]} =
               Resources.add_reference(skill(%{}), 42, "disk")
    end

    test "preserves existing references and their order" do
      first = %{"file_id" => "1", "provider" => "disk"}
      s = skill(%{resources: %{"references" => [first]}})

      assert %{"references" => [^first, %{"file_id" => "2"}]} =
               Resources.add_reference(s, "2", "disk")
    end

    # A retried upload must not list the same file twice.
    test "is a no-op for a file_id already referenced" do
      refs = [%{"file_id" => "1", "provider" => "disk"}]
      s = skill(%{resources: %{"references" => refs}})

      assert Resources.add_reference(s, "1", "disk") == %{"references" => refs}
    end

    test "leaves other namespaces in the resources map untouched" do
      s = skill(%{resources: %{"references" => [], "assets" => ["kept"]}})

      assert %{"assets" => ["kept"]} = Resources.add_reference(s, "1", "disk")
    end

    # A row written before `resources` had a default, or one loaded with the field unset.
    test "builds a resources map when the skill has none" do
      assert Resources.add_reference(skill(%{resources: nil}), "1", "disk") ==
               %{"references" => [%{"file_id" => "1", "provider" => "disk"}]}
    end
  end

  describe "remove_reference/2" do
    test "removes a referenced file" do
      refs = [
        %{"file_id" => "1", "provider" => "disk"},
        %{"file_id" => "2", "provider" => "disk"}
      ]

      s = skill(%{resources: %{"references" => refs}})

      assert Resources.remove_reference(s, "1") ==
               %{"references" => [%{"file_id" => "2", "provider" => "disk"}]}
    end

    test "accepts an integer file_id" do
      refs = [%{"file_id" => "1", "provider" => "disk"}]
      s = skill(%{resources: %{"references" => refs}})

      assert Resources.remove_reference(s, 1) == %{"references" => []}
    end

    test "is a no-op for an absent file_id" do
      refs = [%{"file_id" => "1", "provider" => "disk"}]
      s = skill(%{resources: %{"references" => refs}})

      assert Resources.remove_reference(s, "9") == %{"references" => refs}
    end

    test "is a no-op when the skill has no resources map" do
      assert Resources.remove_reference(skill(%{resources: nil}), "1") == %{"references" => []}
    end
  end

  describe "root/1" do
    test "derives from the skill name" do
      assert Resources.root(skill(%{name: "pricing-faq"})) == ".agents/skills/pricing-faq"
    end

    # References are document ids now, so a rename cannot strand anything — it only changes
    # where subsequent uploads land. There is no stored root to be sticky about.
    test "follows a rename" do
      assert Resources.root(skill(%{name: "new-name"})) == ".agents/skills/new-name"
    end

    test "is the parent of references_dir/1" do
      s = skill(%{name: "pricing-faq"})
      assert Resources.references_dir(s) == Path.join(Resources.root(s), "references")
    end
  end

  describe "references_dir/1" do
    test "is the references child of the derived root" do
      assert Resources.references_dir(skill(%{name: "pricing-faq"})) ==
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

    property "add then remove round-trips to the original references" do
      check all(
              file_ids <- uniq_list_of(string(:alphanumeric, min_length: 1), max_length: 5),
              new_id <- string(:alphanumeric, min_length: 1),
              max_runs: 200
            ) do
        refs = Enum.map(file_ids, &%{"file_id" => &1, "provider" => "disk"})
        s = skill(%{resources: %{"references" => refs}})

        added = Resources.add_reference(s, new_id, "disk")
        round_tripped = Resources.remove_reference(%{s | resources: added}, new_id)

        # Removing the id just added restores exactly what was there — unless it was
        # already present, in which case add was a no-op and remove drops it.
        expected =
          if new_id in file_ids, do: Enum.reject(refs, &(&1["file_id"] == new_id)), else: refs

        assert round_tripped == %{"references" => expected}
      end
    end
  end
end

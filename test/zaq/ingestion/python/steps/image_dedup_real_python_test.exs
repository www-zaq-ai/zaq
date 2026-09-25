defmodule Zaq.Ingestion.Python.Steps.ImageDedupRealPythonTest do
  use ExUnit.Case, async: false

  @moduletag :real_python

  alias Zaq.Ingestion.Python.Runner
  alias Zaq.Ingestion.Python.Steps.ImageDedup

  test "the provisioned runner removes one duplicate without changing the survivor" do
    root =
      Path.join(System.tmp_dir!(), "zaq_image_dedup_#{System.unique_integer([:positive])}")

    images = Path.join(root, "images")
    File.mkdir_p!(images)
    on_exit(fn -> File.rm_rf!(root) end)

    fixture = Path.join(File.cwd!(), "test/fixtures/python/tiny.png")
    original_bytes = File.read!(fixture)
    first = Path.join(images, "first.png")
    second = Path.join(images, "second.png")
    File.cp!(fixture, first)
    File.cp!(fixture, second)

    provisioned_python = Path.join(File.cwd!(), ".venv/bin/python3")
    assert Runner.python_executable() == provisioned_python
    assert {"Python 3.13" <> _, 0} = System.cmd(provisioned_python, ["--version"])

    fetched_script = Path.join(File.cwd!(), "priv/python/crawler-ingest/image_dedup.py")
    selected_script = Path.join(Runner.scripts_dir(), "image_dedup.py")
    assert File.read!(selected_script) == File.read!(fetched_script)

    manifest =
      Runner.scripts_dir()
      |> Path.join("manifest.json")
      |> File.read!()
      |> Jason.decode!()

    revision =
      File.cwd!()
      |> Path.join("priv/python/crawler-ingest.revision")
      |> File.read!()
      |> String.trim()

    assert manifest["commit"] == revision

    assert {:ok, output} = ImageDedup.run(images, threshold: 0)
    assert output =~ "Deleted 1 duplicate"

    assert [survivor] = Path.wildcard(Path.join(images, "*.png"))
    assert File.read!(survivor) == original_bytes

    removed = if survivor == first, do: second, else: first
    mapping = File.read!(Path.join(images, "duplicate_mapping.txt"))
    assert "# Total duplicates: 1" in String.split(mapping, "\n")
    assert "#{removed} -> #{survivor}" in String.split(mapping, "\n")
  end
end

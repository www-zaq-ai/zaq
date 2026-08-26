defmodule Zaq.Ingestion.ExternalSidecarStoreTest do
  use ExUnit.Case, async: true

  alias Zaq.Ingestion.ExternalSidecarStore

  setup do
    relative_dir = "external-sidecar-store-test-#{System.unique_integer([:positive])}"
    absolute_dir = Path.join(base_path(), relative_dir)

    on_exit(fn -> File.rm_rf!(absolute_dir) end)

    {:ok, relative_dir: relative_dir, absolute_dir: absolute_dir}
  end

  test "deletes an existing regular file", %{
    relative_dir: relative_dir,
    absolute_dir: absolute_dir
  } do
    relative_path = Path.join(relative_dir, "existing.txt")
    absolute_path = Path.join(absolute_dir, "existing.txt")
    File.mkdir_p!(absolute_dir)
    File.write!(absolute_path, "sidecar")

    assert File.exists?(absolute_path)
    assert :ok = ExternalSidecarStore.delete(relative_path)
    refute File.exists?(absolute_path)
  end

  test "treats a missing file as already deleted", %{
    relative_dir: relative_dir,
    absolute_dir: absolute_dir
  } do
    relative_path = Path.join(relative_dir, "missing.txt")
    absolute_path = Path.join(absolute_dir, "missing.txt")

    refute File.exists?(absolute_path)
    assert :ok = ExternalSidecarStore.delete(relative_path)
    refute File.exists?(absolute_path)
  end

  test "passes through filesystem errors for directory targets", %{
    relative_dir: relative_dir,
    absolute_dir: absolute_dir
  } do
    relative_path = Path.join(relative_dir, "directory")
    directory_path = Path.join(absolute_dir, "directory")
    sentinel_path = Path.join(directory_path, "sentinel")
    File.mkdir_p!(directory_path)
    File.write!(sentinel_path, "keep")

    assert {:error, reason} = ExternalSidecarStore.delete(relative_path)
    refute reason == :enoent
    assert File.dir?(directory_path)
    assert File.exists?(sentinel_path)
  end

  defp base_path do
    Path.join(System.tmp_dir!(), "zaq_external_sidecars")
  end
end

defmodule Zaq.StorageTest do
  use Zaq.DataCase, async: false

  alias Zaq.Materialization.Handle
  alias Zaq.Storage

  defmodule TestConfig do
    def get(:zaq, Zaq.Storage, _default, opts), do: Keyword.fetch!(opts, :storage_config)
  end

  setup do
    root = Path.join(System.tmp_dir!(), "storage_test_#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(root)

    opts = [config: TestConfig, storage_config: [base_path: root, volumes: %{"archives" => root}]]

    on_exit(fn ->
      File.rm_rf!(root)
    end)

    {:ok, root: root, storage_opts: opts}
  end

  test "list_documents/1 paginates directory entries with a signed cursor", %{
    root: root,
    storage_opts: opts
  } do
    File.write!(Path.join(root, "a.md"), "a")
    File.write!(Path.join(root, "b.md"), "b")
    File.write!(Path.join(root, "c.md"), "c")

    assert {:ok, first} =
             Storage.list_documents(
               %{"filters" => %{"parent" => "archives"}, "page_size" => 2},
               opts
             )

    assert Enum.map(first.entries, & &1.name) == ["a.md", "b.md"]
    assert first.pagination.has_more? == true
    assert first.pagination.page_size == 2
    assert is_binary(first.pagination.cursor)

    assert {:ok, %{type: "storage_page_cursor", locator: locator}} =
             Handle.verify(first.pagination.cursor)

    assert locator["volume"] == "archives"
    assert locator["path"] == "."
    assert locator["source"] == "archives/b.md"

    assert {:ok, second} =
             Storage.list_documents(
               %{
                 "filters" => %{"parent" => "archives"},
                 "page_size" => 2,
                 "page_token" => first.pagination.cursor
               },
               opts
             )

    assert Enum.map(second.entries, & &1.name) == ["c.md"]
    assert second.pagination.has_more? == false
    assert second.pagination.cursor == nil
  end

  test "entries keep a stable id across ZAQ-managed rename", %{root: root, storage_opts: opts} do
    File.write!(Path.join(root, "before.md"), "a")

    assert {:ok, before} = Storage.file_info("archives", "before.md", opts)
    assert :ok = Storage.rename_entry("archives", "before.md", "after.md", opts)
    assert {:ok, after_entry} = Storage.file_info("archives", "after.md", opts)

    assert after_entry.id == before.id
    assert after_entry.relative_path == "after.md"
  end

  test "external rename is treated as a new entry", %{root: root, storage_opts: opts} do
    File.write!(Path.join(root, "before.md"), "a")

    assert {:ok, before} = Storage.file_info("archives", "before.md", opts)
    File.rename!(Path.join(root, "before.md"), Path.join(root, "after.md"))
    assert {:ok, after_entry} = Storage.file_info("archives", "after.md", opts)

    refute after_entry.id == before.id
  end

  test "list_documents/1 rejects a cursor for a different parent", %{
    root: root,
    storage_opts: opts
  } do
    File.mkdir_p!(Path.join(root, "manuals"))
    File.write!(Path.join(root, "a.md"), "a")

    assert {:ok, first} =
             Storage.list_documents(
               %{"filters" => %{"parent" => "archives"}, "page_size" => 1},
               opts
             )

    assert {:error, :cursor_context_mismatch} =
             Storage.list_documents(
               %{
                 "filters" => %{"parent" => "archives/manuals"},
                 "page_token" => first.pagination.cursor
               },
               opts
             )
  end
end

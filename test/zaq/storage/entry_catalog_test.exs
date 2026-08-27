defmodule Zaq.Storage.EntryCatalogTest do
  use Zaq.DataCase, async: true

  alias Zaq.Repo
  alias Zaq.Storage.EntryCatalog

  test "recovers an active noncanonical path without creating a canonical row" do
    volume = "documents"
    {:ok, root} = EntryCatalog.ensure(volume, "", :directory)

    %EntryCatalog{}
    |> EntryCatalog.changeset(%{
      volume: volume,
      relative_path: "./document.md",
      kind: "file",
      parent_id: root.id
    })
    |> Repo.insert!()

    assert {:ok, nil} = EntryCatalog.ensure(volume, "././document.md", :file)

    assert [%EntryCatalog{relative_path: "./document.md"}] =
             Repo.all(
               from e in EntryCatalog,
                 where:
                   e.volume == ^volume and e.relative_path == "./document.md" and
                     is_nil(e.deleted_at)
             )

    assert Repo.get_by(EntryCatalog, volume: volume, relative_path: "document.md") == nil
  end

  test "does not create a root entry when ensuring ./ on an empty volume" do
    volume = "empty"

    assert {:ok, nil} = EntryCatalog.ensure(volume, "./", :directory)
    assert Repo.all(from e in EntryCatalog, where: e.volume == ^volume) == []
    assert EntryCatalog.get_active(volume, "") == nil
  end

  test "returns the changeset for a nonrecoverable insert error" do
    volume = "documents"

    assert {:error, changeset} = EntryCatalog.ensure(volume, ".", :symlink)
    assert "is invalid" in errors_on(changeset).kind
    assert Repo.all(from e in EntryCatalog, where: e.volume == ^volume) == []
  end

  test "tombstoning a nil path only removes the volume root" do
    volume = "documents"
    {:ok, root} = EntryCatalog.ensure(volume, "", :directory)
    {:ok, child} = EntryCatalog.ensure(volume, "document.md", :file)
    root_id = root.id
    child_id = child.id

    assert :ok = EntryCatalog.tombstone(volume, nil)

    assert %{id: ^root_id, deleted_at: deleted_at} = Repo.get!(EntryCatalog, root_id)

    assert not is_nil(deleted_at)
    assert %{id: ^child_id, deleted_at: nil} = Repo.get!(EntryCatalog, child_id)
  end

  test "renaming a directory preserves descendant ids by updating their paths" do
    volume = "documents"
    {:ok, folder} = EntryCatalog.ensure(volume, "old", :directory)
    {:ok, child} = EntryCatalog.ensure(volume, "old/file.pdf", :file)
    {:ok, nested} = EntryCatalog.ensure(volume, "old/sub/notes.md", :file)

    assert {:ok, %{id: folder_id, relative_path: "new"}} =
             EntryCatalog.rename(volume, "old", "new")

    assert folder_id == folder.id

    assert %{id: child_id, relative_path: "new/file.pdf", parent_id: ^folder_id} =
             EntryCatalog.get_active(volume, "new/file.pdf")

    assert child_id == child.id

    assert %{id: nested_id, relative_path: "new/sub/notes.md"} =
             EntryCatalog.get_active(volume, "new/sub/notes.md")

    assert nested_id == nested.id
    assert EntryCatalog.get_active(volume, "old/file.pdf") == nil
  end

  test "ensuring an empty path creates the canonical volume root" do
    volume = "documents"

    assert {:ok, %EntryCatalog{id: id, relative_path: ".", parent_id: nil}} =
             EntryCatalog.ensure(volume, "", :directory)

    assert %EntryCatalog{id: ^id, relative_path: ".", parent_id: nil} =
             EntryCatalog.get_active(volume, "")
  end
end

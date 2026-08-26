defmodule Zaq.StorageTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  alias Zaq.Accounts.People
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Materialization.Handle
  alias Zaq.Permissions
  alias Zaq.Repo
  alias Zaq.Storage
  alias Zaq.Storage.StorageEntry

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

    admin_opts = Keyword.put(opts, :skip_permissions, true)

    assert {:ok, first} =
             Storage.list_documents(
               %{"filters" => %{"parent" => "archives"}, "page_size" => 2},
               admin_opts
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
               admin_opts
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

    admin_opts = Keyword.put(opts, :skip_permissions, true)

    assert {:ok, first} =
             Storage.list_documents(
               %{"filters" => %{"parent" => "archives"}, "page_size" => 1},
               admin_opts
             )

    assert {:error, :cursor_context_mismatch} =
             Storage.list_documents(
               %{
                 "filters" => %{"parent" => "archives/manuals"},
                 "page_token" => first.pagination.cursor
               },
               admin_opts
             )
  end

  test "list_documents/1 hides entries without resource permissions from nil actors", %{
    root: root,
    storage_opts: opts
  } do
    File.write!(Path.join(root, "private.md"), "private")

    assert {:ok, page} =
             Storage.list_documents(%{"filters" => %{"parent" => "archives"}}, opts)

    assert page.entries == []
  end

  test "list_documents/1 hides entries without resource permissions from ordinary actors", %{
    root: root,
    storage_opts: opts
  } do
    File.write!(Path.join(root, "private.md"), "private")
    person = person_fixture()

    assert {:ok, page} =
             Storage.list_documents(
               %{"filters" => %{"parent" => "archives"}},
               Keyword.put(opts, :actor, %{person_id: person.id})
             )

    assert page.entries == []
  end

  test "list_documents/1 returns entries without resource permissions only for trusted bypass", %{
    root: root,
    storage_opts: opts
  } do
    File.write!(Path.join(root, "private.md"), "private")

    assert {:ok, page} =
             Storage.list_documents(
               %{"filters" => %{"parent" => "archives"}},
               Keyword.put(opts, :skip_permissions, true)
             )

    assert Enum.map(page.entries, & &1.name) == ["private.md"]
  end

  test "list_documents/1 hides entries with resource permissions from nil actors", %{
    root: root,
    storage_opts: opts
  } do
    File.write!(Path.join(root, "restricted.md"), "restricted")
    assert {:ok, entry} = Storage.file_info("archives", "restricted.md", opts)
    person = person_fixture()
    {:ok, _permission} = Permissions.grant(%StorageEntry{id: entry.id}, %{person_id: person.id})

    assert {:ok, page} =
             Storage.list_documents(%{"filters" => %{"parent" => "archives"}}, opts)

    assert page.entries == []
  end

  test "list_documents/1 returns restricted entries to actors with storage permissions", %{
    root: root,
    storage_opts: opts
  } do
    File.write!(Path.join(root, "restricted.md"), "restricted")
    assert {:ok, entry} = Storage.file_info("archives", "restricted.md", opts)
    person = person_fixture()
    {:ok, _permission} = Permissions.grant(%StorageEntry{id: entry.id}, %{person_id: person.id})

    assert {:ok, page} =
             Storage.list_documents(
               %{"filters" => %{"parent" => "archives"}},
               Keyword.put(opts, :actor, %{person_id: person.id})
             )

    assert Enum.map(page.entries, & &1.name) == ["restricted.md"]
  end

  test "materialize_document enforces storage resource permissions", %{
    root: root,
    storage_opts: opts
  } do
    File.write!(Path.join(root, "restricted.md"), "restricted")
    assert {:ok, entry} = Storage.file_info("archives", "restricted.md", opts)
    person = person_fixture()
    {:ok, _permission} = Permissions.grant(%StorageEntry{id: entry.id}, %{person_id: person.id})

    assert {:error, :unauthorized} = Storage.materialize_document(%{"file_id" => entry.id}, opts)

    assert {:ok, %{content: "restricted"}} =
             Storage.materialize_document(
               %{"file_id" => entry.id},
               Keyword.put(opts, :actor, %{person_id: person.id})
             )

    assert {:ok, %{content: "restricted"}} =
             Storage.materialize_document(
               %{"file_id" => entry.id},
               Keyword.put(opts, :skip_permissions, true)
             )
  end

  test "search_documents/1 and describe_document/2 keep ungranted entries private", %{
    root: root,
    storage_opts: opts
  } do
    File.write!(Path.join(root, "private.md"), "private")
    assert {:ok, entry} = Storage.file_info("archives", "private.md", opts)

    assert {:ok, page} = Storage.search_documents(%{"query" => "private"}, opts)
    assert page.entries == []
    assert {:error, :unauthorized} = Storage.describe_document(entry.id, opts)

    assert {:ok, page} =
             Storage.search_documents(
               %{"query" => "private"},
               Keyword.put(opts, :skip_permissions, true)
             )

    assert Enum.map(page.entries, & &1.name) == ["private.md"]

    assert {:ok, ^entry} =
             Storage.describe_document(entry.id, Keyword.put(opts, :skip_permissions, true))
  end

  property "ungranted storage entries are private by default", %{root: root, storage_opts: opts} do
    check all(
            name <- StreamData.string(:alphanumeric, min_length: 1, max_length: 12),
            max_runs: 12
          ) do
      filename = "#{name}.md"
      File.rm_rf!(root)
      File.mkdir_p!(root)
      File.write!(Path.join(root, filename), "private")

      assert {:ok, page} = Storage.list_documents(%{"filters" => %{"parent" => "archives"}}, opts)
      assert page.entries == []

      assert {:ok, page} =
               Storage.list_documents(
                 %{"filters" => %{"parent" => "archives"}},
                 Keyword.put(opts, :skip_permissions, true)
               )

      assert Enum.map(page.entries, & &1.name) == [filename]
    end
  end

  test "materialize_document resolves current disk ChannelConfig when no storage opts are passed",
       %{
         root: root
       } do
    original_storage = Application.get_env(:zaq, Zaq.Storage)
    Application.put_env(:zaq, Zaq.Storage, base_path: root, volumes: %{})

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.Storage, original_storage || [])
    end)

    File.mkdir_p!(Path.join(root, "configured/archive"))
    File.write!(Path.join(root, "configured/archive/report.md"), "# report")

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Disk storage materialization",
        provider: "disk",
        kind: "data_source",
        enabled: true,
        settings: %{"volumes" => [%{"name" => "archives", "path" => "configured/archive"}]}
      })
      |> Repo.insert!()

    assert {:ok, %{content: "# report", encoding: nil}} =
             Storage.materialize_document(%{file_id: "archives/report.md", config_id: config.id},
               skip_permissions: true
             )
  end

  defp person_fixture do
    unique = System.unique_integer([:positive])
    {:ok, person} = People.create_person(%{full_name: "Storage Person #{unique}"})
    person
  end
end

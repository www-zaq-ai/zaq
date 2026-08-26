defmodule Zaq.StorageTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  alias Zaq.Accounts.People
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Materialization.Handle
  alias Zaq.Permissions
  alias Zaq.Repo
  alias Zaq.Storage
  alias Zaq.Storage.EntryCatalog
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
    original = Application.get_env(:zaq, Zaq.Storage)
    Application.put_env(:zaq, Zaq.Storage, base_path: root, volumes: %{"archives" => root})
    on_exit(fn -> Application.put_env(:zaq, Zaq.Storage, original || []) end)

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

  test "list_documents/1 omits a configured volume whose root does not exist", %{
    root: root,
    storage_opts: opts
  } do
    missing_root = Path.join(root, "not-created")

    opts =
      Keyword.put(opts, :storage_config,
        base_path: root,
        volumes: %{"empty" => missing_root}
      )

    assert {:ok, page} =
             Storage.list_documents(%{}, Keyword.put(opts, :skip_permissions, true))

    assert page.entries == []
    assert page.scanned == 0
  end

  test "list_documents/1 keeps existing roots when another configured root does not exist", %{
    root: root,
    storage_opts: opts
  } do
    opts =
      Keyword.put(opts, :storage_config,
        base_path: root,
        volumes: %{"archives" => root, "empty" => Path.join(root, "not-created")}
      )

    assert {:ok, page} =
             Storage.list_documents(%{}, Keyword.put(opts, :skip_permissions, true))

    assert Enum.map(page.entries, & &1.name) == ["archives"]
    assert page.scanned == 1
  end

  test "list_documents/1 root path combines immediate entries from every existing volume", %{
    root: root,
    storage_opts: opts
  } do
    alpha = Path.join(root, "alpha")
    beta = Path.join(root, "beta")
    empty = Path.join(root, "empty")
    File.mkdir_p!(Path.join(alpha, "nested"))
    File.mkdir_p!(beta)
    File.mkdir_p!(empty)
    File.write!(Path.join(alpha, "a.md"), "a")
    File.write!(Path.join(alpha, "nested/deep.md"), "deep")
    File.write!(Path.join(beta, "b.md"), "b")

    opts =
      Keyword.put(opts, :storage_config,
        base_path: root,
        volumes: %{
          "alpha" => alpha,
          "beta" => beta,
          "empty" => empty,
          "missing" => Path.join(root, "not-created")
        }
      )

    assert {:ok, page} =
             Storage.list_documents(
               %{"path" => "/"},
               Keyword.put(opts, :skip_permissions, true)
             )

    assert page.entries |> Enum.map(& &1.source) |> Enum.sort() ==
             ["alpha/a.md", "alpha/nested", "beta/b.md"]

    assert page.scanned == 3
  end

  test "list_documents/1 root path filters combined entries by storage permissions", %{
    root: root,
    storage_opts: opts
  } do
    alpha = Path.join(root, "alpha")
    beta = Path.join(root, "beta")
    File.mkdir_p!(alpha)
    File.mkdir_p!(beta)
    File.write!(Path.join(alpha, "visible.md"), "visible")
    File.write!(Path.join(beta, "private.md"), "private")

    opts =
      Keyword.put(opts, :storage_config,
        base_path: root,
        volumes: %{"alpha" => alpha, "beta" => beta}
      )

    assert {:ok, visible} = Storage.file_info("alpha", "visible.md", opts)
    person = person_fixture()
    {:ok, _permission} = Permissions.grant(%StorageEntry{id: visible.id}, %{person_id: person.id})

    assert {:ok, page} =
             Storage.list_documents(
               %{"path" => "/"},
               Keyword.put(opts, :actor, %{person_id: person.id})
             )

    assert Enum.map(page.entries, & &1.source) == ["alpha/visible.md"]
    assert page.scanned == 2
  end

  test "list_documents/1 paginates combined volume entries with one root cursor", %{
    root: root,
    storage_opts: opts
  } do
    alpha = Path.join(root, "alpha")
    beta = Path.join(root, "beta")
    File.mkdir_p!(alpha)
    File.mkdir_p!(beta)
    File.write!(Path.join(alpha, "a.md"), "a")
    File.write!(Path.join(beta, "b.md"), "b")

    opts =
      opts
      |> Keyword.put(:storage_config,
        base_path: root,
        volumes: %{"alpha" => alpha, "beta" => beta}
      )
      |> Keyword.put(:skip_permissions, true)

    assert {:ok, first} = Storage.list_documents(%{"path" => "/", "page_size" => 1}, opts)
    assert Enum.map(first.entries, & &1.source) == ["alpha/a.md"]
    assert first.pagination.has_more? == true

    assert {:ok, second} =
             Storage.list_documents(
               %{"path" => "/", "page_size" => 1, "page_token" => first.pagination.cursor},
               opts
             )

    assert Enum.map(second.entries, & &1.source) == ["beta/b.md"]
    assert second.pagination.has_more? == false
  end

  test "list_documents/1 still filters existing volume roots by storage permissions", %{
    storage_opts: opts
  } do
    assert {:ok, page} = Storage.list_documents(%{}, opts)

    assert page.entries == []
    assert page.scanned == 1
  end

  test "filesystem delegates use configured defaults and nil-volume paths", %{root: root} do
    original = Application.get_env(:zaq, Zaq.Storage)
    Application.put_env(:zaq, Zaq.Storage, base_path: root, volumes: %{"archives" => root})

    on_exit(fn -> Application.put_env(:zaq, Zaq.Storage, original || []) end)

    assert :ok = Storage.create_directory("archives", "nested")
    assert {:ok, path} = Storage.save_file("archives", "nested/report.md", "report")
    assert path == Path.join(root, "nested/report.md")
    assert File.read!(path) == "report"
    assert {:ok, info} = Storage.file_info("archives", "nested/report.md")
    assert info.size == byte_size("report")
    assert {:ok, nil_volume} = Storage.file_info(nil, "nested/report.md")
    assert nil_volume.relative_path == "nested/report.md"
    assert {:ok, duplicate} = Storage.upload_file("archives", "nested/report.md", "copy")
    assert duplicate == Path.join(root, "nested/report(1).md")
    assert {:ok, resolved} = Storage.resolve_path("archives", "nested/report.md")
    assert resolved == path
    assert :ok = Storage.rename_entry("archives", "nested/report.md", "nested/renamed.md")
    assert File.exists?(Path.join(root, "nested/renamed.md"))
    assert :ok = Storage.delete_directory("archives", "nested")
    refute File.exists?(Path.join(root, "nested"))
  end

  test "delete_document deletes files and directories and tombstones catalog entries", %{
    root: root,
    storage_opts: opts
  } do
    original = Application.get_env(:zaq, Zaq.Storage)
    Application.put_env(:zaq, Zaq.Storage, base_path: root, volumes: %{"archives" => root})
    on_exit(fn -> Application.put_env(:zaq, Zaq.Storage, original || []) end)

    File.mkdir_p!(Path.join(root, "folder/sub"))
    File.write!(Path.join(root, "folder/sub/file.md"), "content")
    assert {:ok, file} = Storage.file_info("archives", "folder/sub/file.md", opts)
    assert {:ok, folder} = Storage.file_info("archives", "folder", opts)

    assert {:ok, %{status: "deleted"}} = Storage.delete_document(file.id)
    refute File.exists?(Path.join(root, "folder/sub/file.md"))
    assert Repo.get(EntryCatalog, file.id).deleted_at != nil

    assert {:ok, %{status: "deleted"}} = Storage.delete_document(folder.id)

    refute File.exists?(Path.join(root, "folder"))
    assert Repo.get(EntryCatalog, folder.id).deleted_at != nil
  end

  test "document grants list person and team targets with normalized fields", %{
    root: root,
    storage_opts: opts
  } do
    File.write!(Path.join(root, "shared.md"), "shared")
    assert {:ok, entry} = Storage.file_info("archives", "shared.md", opts)
    person = person_fixture()

    {:ok, team} =
      People.create_team(%{name: "Storage Team #{System.unique_integer([:positive])}"})

    assert {:ok, person_permission} =
             Storage.grant_document_access(entry.id, %{
               person_id: person.id,
               access_rights: ["read", "write"]
             })

    assert {:ok, _} =
             Storage.grant_document_access(entry.id, %{team_id: team.id, access_rights: ["read"]})

    assert :ok = Permissions.revoke(%StorageEntry{id: entry.id}, person_permission)
    assert person_permission.person_id == person.id
    assert person_permission.access_rights == ["read", "write"]

    assert {:ok, %{permissions: [grant], public?: false}} =
             Storage.list_document_grants(entry.id)
             |> then(fn {:ok, %{permissions: grants} = result} ->
               {:ok, %{result | permissions: Enum.reject(grants, &(&1.type == "person"))}}
             end)

    assert grant.type == "team"
    assert grant.target_id == to_string(team.id)
    assert grant.name == team.name
    assert grant.access_rights == ["read"]
  end

  test "volume_stats counts recursive files and folders and sorts roots", %{
    root: root,
    storage_opts: opts
  } do
    alpha = Path.join(root, "alpha")
    beta = Path.join(root, "beta")
    File.mkdir_p!(Path.join(alpha, "nested/deeper"))
    File.mkdir_p!(beta)
    File.write!(Path.join(alpha, "one.md"), "1")
    File.write!(Path.join(alpha, "nested/two.md"), "22")
    File.write!(Path.join(alpha, "nested/deeper/three.md"), "333")
    File.write!(Path.join(beta, "four.md"), "4444")

    opts =
      Keyword.put(opts, :storage_config,
        base_path: root,
        volumes: %{"zeta" => beta, "alpha" => alpha}
      )

    assert {:ok, stats} = Storage.volume_stats(opts)
    assert stats.files_count == 4
    assert stats.folders_count == 2
    assert stats.principals_count == 0
    assert stats.root_folders == ["alpha", "zeta"]
  end

  test "listing can include exact permissions for each entry", %{root: root, storage_opts: opts} do
    File.write!(Path.join(root, "permitted.md"), "permitted")
    assert {:ok, entry} = Storage.file_info("archives", "permitted.md", opts)

    {:ok, team} =
      People.create_team(%{name: "Permission Team #{System.unique_integer([:positive])}"})

    {:ok, _} =
      Storage.grant_document_access(entry.id, %{team_id: team.id, access_rights: ["read"]})

    assert {:ok, page} =
             Storage.list_documents(
               %{"filters" => %{"parent" => "archives"}, "include_permissions" => true},
               Keyword.put(opts, :skip_permissions, true)
             )

    [grant] = page.permissions_by_id[entry.id]
    assert grant.type == "team"
    assert grant.target_id == to_string(team.id)
    assert grant.access_rights == ["read"]
  end

  test "list_documents validates and clamps page sizes", %{storage_opts: opts} do
    admin = Keyword.put(opts, :skip_permissions, true)

    for value <- [501, "501"] do
      assert {:ok, page} = Storage.list_documents(%{"page_size" => value}, admin)
      assert page.pagination.page_size == 500
    end

    for value <- [0, -1, "0", "wat", [], %{}] do
      assert {:error, :invalid_page_size} = Storage.list_documents(%{"page_size" => value}, admin)
    end
  end

  test "list_documents rejects malformed and wrong-type cursors", %{
    root: root,
    storage_opts: opts
  } do
    File.write!(Path.join(root, "cursor.md"), "cursor")
    admin = Keyword.put(opts, :skip_permissions, true)

    assert {:error, :invalid_page_token} =
             Storage.list_documents(
               %{"page_token" => Handle.issue("wrong", %{}) |> elem(1)},
               admin
             )

    assert {:ok, token} =
             Handle.issue("storage_page_cursor", %{"volume" => "archives", "path" => "."})

    assert {:error, :invalid_page_token} =
             Storage.list_documents(
               %{"filters" => %{"parent" => "archives"}, "page_token" => token},
               admin
             )

    assert {:ok, nonbinary_source} =
             Handle.issue("storage_page_cursor", %{
               "volume" => "archives",
               "path" => ".",
               "source" => 42
             })

    assert {:error, :invalid_page_token} =
             Storage.list_documents(
               %{"filters" => %{"parent" => "archives"}, "page_token" => nonbinary_source},
               admin
             )

    assert {:error, :invalid_materialization_handle} =
             Storage.list_documents(%{"page_token" => 42}, admin)
  end

  test "disk ChannelConfig resolution handles zero, one, and multiple configs", %{root: root} do
    original = Application.get_env(:zaq, Zaq.Storage)
    Application.put_env(:zaq, Zaq.Storage, base_path: root, volumes: %{})
    on_exit(fn -> Application.put_env(:zaq, Zaq.Storage, original || []) end)

    assert {:error, :disk_channel_config_not_found} = Storage.list_documents(%{})
    _one = disk_config("one", root)
    assert {:ok, _page} = Storage.list_documents(%{})
    Repo.query!("DROP INDEX IF EXISTS channel_configs_provider_index")
    _two = disk_config("two", root)
    assert {:error, :ambiguous_disk_channel_config} = Storage.list_documents(%{})

    assert {:error, :disk_channel_config_not_found} =
             Storage.list_documents(%{"config_id" => "bad"})

    assert {:error, :disk_channel_config_not_found} =
             Storage.list_documents(%{"config_id" => []})
  end

  test "materialization and updates handle binary content, overwrites, moves, and errors", %{
    root: root,
    storage_opts: opts
  } do
    File.write!(Path.join(root, "binary.bin"), <<255, 0, 1>>)
    assert {:ok, binary_entry} = Storage.file_info("archives", "binary.bin", opts)

    assert {:ok, %{content: encoded, encoding: "base64"}} =
             Storage.materialize_document(
               %{"file_id" => binary_entry.id},
               Keyword.put(opts, :skip_permissions, true)
             )

    assert Base.decode64!(encoded) == <<255, 0, 1>>

    assert {:ok, %{entry: entry}} =
             Storage.persist_document(
               %{"name" => "draft.md", "content" => "old"},
               Keyword.put(opts, :storage_config,
                 base_path: root,
                 volumes: %{"archives" => root},
                 default_volume: "archives"
               )
             )

    assert {:ok, %{status: "updated", entry: updated}} =
             Storage.update_document(%{"file_id" => entry.id, "content" => "new"}, opts)

    assert File.read!(Path.join(root, "draft.md")) == "new"
    assert updated.relative_path == "draft.md"

    assert {:ok, %{entry: moved}} =
             Storage.update_document(%{"file_id" => entry.id, "name" => "renamed.md"}, opts)

    assert moved.relative_path == "renamed.md"

    assert {:error, :volume_required} =
             Storage.update_document(%{"file_id" => moved.id, "path" => "other"}, opts)

    multi_opts =
      Keyword.put(opts, :storage_config,
        base_path: root,
        volumes: %{"archives" => root, "other" => Path.join(root, "other")}
      )

    assert {:error, :cross_volume_move_unsupported} =
             Storage.update_document(%{"file_id" => moved.id, "path" => "other/docs"}, multi_opts)

    assert {:error, :invalid_base64} =
             Storage.update_document(
               %{"file_id" => moved.id, "content" => "%%%", "encoding" => "base64"},
               opts
             )

    assert {:error, :file_id_required} = Storage.update_document(%{"content" => "x"}, opts)

    assert {:error, :name_required} =
             Storage.persist_document(
               %{"name" => "", "content" => "x"},
               Keyword.put(opts, :storage_config,
                 base_path: root,
                 volumes: %{"archives" => root},
                 default_volume: "archives"
               )
             )

    assert {:error, :file_id_required} = Storage.materialize_document(%{"file_id" => ""}, opts)
  end

  test "search_documents returns an empty page when a configured root is missing", %{
    root: root,
    storage_opts: opts
  } do
    missing = Path.join(root, "missing")
    opts = Keyword.put(opts, :storage_config, base_path: root, volumes: %{"missing" => missing})

    assert {:ok, %{entries: [], scanned: 0}} =
             Storage.search_documents(%{"query" => "anything"}, opts)
  end

  test "list_documents/1 returns an explicit error when a configured root is not a directory", %{
    root: root,
    storage_opts: opts
  } do
    file_root = Path.join(root, "file-root")
    File.write!(file_root, "not a directory")

    opts =
      Keyword.put(opts, :storage_config,
        base_path: root,
        volumes: %{"broken" => file_root}
      )

    assert {:error, {:volume_unavailable, "broken", :not_a_directory}} =
             Storage.list_documents(%{}, Keyword.put(opts, :skip_permissions, true))
  end

  test "list_documents/1 returns other root stat failures instead of treating them as empty", %{
    root: root,
    storage_opts: opts
  } do
    loop_root = Path.join(root, "symlink-loop")
    File.ln_s!(loop_root, loop_root)

    opts =
      Keyword.put(opts, :storage_config,
        base_path: root,
        volumes: %{"broken" => loop_root}
      )

    assert {:error, {:volume_unavailable, "broken", :eloop}} =
             Storage.list_documents(%{}, Keyword.put(opts, :skip_permissions, true))
  end

  test "entries keep a stable id across ZAQ-managed rename", %{root: root, storage_opts: opts} do
    File.write!(Path.join(root, "before.md"), "a")

    assert {:ok, before} = Storage.file_info("archives", "before.md", opts)
    assert :ok = Storage.rename_entry("archives", "before.md", "after.md", opts)
    assert {:ok, after_entry} = Storage.file_info("archives", "after.md", opts)

    assert after_entry.id == before.id
    assert after_entry.relative_path == "after.md"
  end

  test "persist_document uses the default volume for an unqualified destination", %{
    root: root,
    storage_opts: opts
  } do
    primary = Path.join(root, "primary")
    secondary = Path.join(root, "secondary")
    File.mkdir_p!(primary)
    File.mkdir_p!(secondary)

    opts =
      Keyword.put(opts, :storage_config,
        base_path: root,
        volumes: %{"primary" => primary, "secondary" => secondary},
        default_volume: "secondary"
      )

    assert {:ok, %{entry: entry}} =
             Storage.persist_document(
               %{"name" => "notes.md", "path" => "docs", "content" => "# notes"},
               opts
             )

    assert entry.volume == "secondary"
    assert entry.relative_path == "docs/notes.md"
    assert File.read!(Path.join(secondary, "docs/notes.md")) == "# notes"
    refute File.exists?(Path.join(primary, "docs/notes.md"))
  end

  test "persist_document gives explicit volume paths precedence over the default volume", %{
    root: root,
    storage_opts: opts
  } do
    primary = Path.join(root, "primary")
    secondary = Path.join(root, "secondary")
    File.mkdir_p!(primary)
    File.mkdir_p!(secondary)

    opts =
      Keyword.put(opts, :storage_config,
        base_path: root,
        volumes: %{"primary" => primary, "secondary" => secondary},
        default_volume: "secondary"
      )

    assert {:ok, %{entry: entry}} =
             Storage.persist_document(
               %{"name" => "notes.md", "path" => "primary/docs", "content" => "# notes"},
               opts
             )

    assert entry.volume == "primary"
    assert entry.relative_path == "docs/notes.md"
    assert File.read!(Path.join(primary, "docs/notes.md")) == "# notes"
  end

  test "persist_document writes to the default volume root when path is omitted", %{
    root: root,
    storage_opts: opts
  } do
    docs = Path.join(root, "docs")
    File.mkdir_p!(docs)

    opts =
      Keyword.put(opts, :storage_config,
        base_path: root,
        volumes: %{"docs" => docs},
        default_volume: "docs"
      )

    assert {:ok, %{entry: entry}} =
             Storage.persist_document(%{"name" => "readme.md", "content" => "readme"}, opts)

    assert entry.volume == "docs"
    assert entry.relative_path == "readme.md"
    assert File.read!(Path.join(docs, "readme.md")) == "readme"
  end

  test "persist_document still requires a volume when no default is configured", %{
    storage_opts: opts
  } do
    assert {:error, :volume_required} =
             Storage.persist_document(
               %{"name" => "notes.md", "path" => "docs", "content" => "# notes"},
               opts
             )
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

  test "describe_document resolves a catalog id through the selected disk ChannelConfig", %{
    root: root,
    storage_opts: opts
  } do
    original_storage = Application.get_env(:zaq, Zaq.Storage)
    Application.put_env(:zaq, Zaq.Storage, base_path: root, volumes: %{})

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.Storage, original_storage || [])
    end)

    configured_root = Path.join(root, "configured/documents")
    File.mkdir_p!(configured_root)
    File.write!(Path.join(configured_root, "guide.md"), "# guide")

    catalog_opts =
      Keyword.put(opts, :storage_config,
        base_path: root,
        volumes: %{"documents" => configured_root}
      )

    assert {:ok, entry} = Storage.file_info("documents", "guide.md", catalog_opts)

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Scoped Disk documents",
        provider: "disk",
        kind: "data_source",
        enabled: true,
        settings: %{
          "volumes" => [%{"name" => "documents", "path" => "configured/documents"}]
        }
      })
      |> Repo.insert!()

    assert {:ok, described} =
             Storage.describe_document(entry.id,
               config_id: config.id,
               skip_permissions: true
             )

    assert described.id == entry.id
    assert described.volume == "documents"
    assert described.relative_path == "guide.md"
  end

  defp person_fixture do
    unique = System.unique_integer([:positive])
    {:ok, person} = People.create_person(%{full_name: "Storage Person #{unique}"})
    person
  end

  defp disk_config(name, _root) do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "Storage #{name}",
      provider: "disk",
      kind: "data_source",
      enabled: true,
      settings: %{"volumes" => [%{"name" => "archives", "path" => "."}]}
    })
    |> Repo.insert!()
  end
end

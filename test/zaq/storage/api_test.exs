defmodule Zaq.Storage.ApiTest do
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.People
  alias Zaq.Event
  alias Zaq.Permissions
  alias Zaq.Storage.Api
  alias Zaq.Storage.StorageEntry

  defmodule TestConfig do
    def get(:zaq, Zaq.Storage, _default, opts),
      do: Keyword.fetch!(opts, :storage_config)
  end

  setup do
    root = Path.join(System.tmp_dir!(), "storage_api_test_#{System.unique_integer([:positive])}")
    archives = Path.join(root, "archives")
    File.mkdir_p!(archives)

    storage_opts = [
      config: TestConfig,
      storage_config: [
        base_path: root,
        volumes: %{"archives" => archives},
        default_volume: "archives"
      ]
    ]

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root, archives: archives, storage_opts: storage_opts}
  end

  test "dispatches volumes_configured?", %{storage_opts: opts} do
    event = event(%{}, opts)
    result = Api.handle_event(event, :volumes_configured?, nil)

    assert_result(event, result, true)
  end

  test "lists entries", %{archives: archives, storage_opts: opts} do
    File.mkdir_p!(Path.join(archives, "manuals"))
    File.write!(Path.join(archives, "manuals/guide.md"), "guide")
    event = event(%{volume: "archives", path: "manuals"}, opts)

    result = Api.handle_event(event, :list_entries, nil)

    assert {:ok, [entry]} = result.response
    assert entry.name == "guide.md"
    assert entry.volume == "archives"
    assert entry.relative_path == "manuals/guide.md"
    assert_result(event, result, result.response)
  end

  test "returns file info", %{archives: archives, storage_opts: opts} do
    File.mkdir_p!(Path.join(archives, "manuals"))
    File.write!(Path.join(archives, "manuals/guide.md"), "guide")
    event = event(%{volume: "archives", path: "manuals/guide.md"}, opts)

    result = Api.handle_event(event, :file_info, nil)

    assert {:ok, entry} = result.response
    assert entry.name == "guide.md"
    assert entry.volume == "archives"
    assert entry.relative_path == "manuals/guide.md"
    assert entry.type == :file
    assert entry.size == 5
    assert_result(event, result, result.response)
  end

  test "creates nested directories", %{archives: archives, storage_opts: opts} do
    event = event(%{volume: "archives", path: "manuals/reference"}, opts)

    result = Api.handle_event(event, :create_directory, nil)

    assert_result(event, result, :ok)
    assert File.dir?(Path.join(archives, "manuals/reference"))
  end

  test "saves a file without deduplicating", %{archives: archives, storage_opts: opts} do
    File.mkdir_p!(Path.join(archives, "manuals"))
    path = Path.join(archives, "manuals/guide.md")
    File.write!(path, "old")
    event = event(%{volume: "archives", path: "manuals/guide.md", content: "new"}, opts)

    result = Api.handle_event(event, :save_file, nil)

    assert_result(event, result, {:ok, path})
    assert File.read!(path) == "new"
  end

  test "uploads a file at a deduplicated path", %{archives: archives, storage_opts: opts} do
    File.mkdir_p!(Path.join(archives, "manuals"))
    original = Path.join(archives, "manuals/guide.md")
    duplicate = Path.join(archives, "manuals/guide(1).md")
    File.write!(original, "original")
    event = event(%{volume: "archives", path: "manuals/guide.md", content: "new"}, opts)

    result = Api.handle_event(event, :upload_file, nil)

    assert_result(event, result, {:ok, duplicate})
    assert File.read!(original) == "original"
    assert File.read!(duplicate) == "new"
  end

  test "deletes a file", %{archives: archives, storage_opts: opts} do
    path = Path.join(archives, "guide.md")
    File.write!(path, "guide")
    event = event(%{volume: "archives", path: "guide.md"}, opts)

    result = Api.handle_event(event, :delete_file, nil)

    assert_result(event, result, :ok)
    refute File.exists?(path)
  end

  test "deletes a directory recursively", %{archives: archives, storage_opts: opts} do
    path = Path.join(archives, "manuals/reference")
    File.mkdir_p!(path)
    File.write!(Path.join(path, "guide.md"), "guide")
    event = event(%{volume: "archives", path: "manuals"}, opts)

    result = Api.handle_event(event, :delete_directory, nil)

    assert_result(event, result, :ok)
    refute File.exists?(Path.join(archives, "manuals"))
  end

  test "renames an entry while preserving its catalog id", %{
    archives: archives,
    storage_opts: opts
  } do
    File.write!(Path.join(archives, "before.md"), "content")
    {:ok, before} = file_info("before.md", opts)
    event = event(%{volume: "archives", old_path: "before.md", new_path: "after.md"}, opts)

    result = Api.handle_event(event, :rename_entry, nil)

    assert_result(event, result, :ok)
    {:ok, after_entry} = file_info("after.md", opts)
    assert after_entry.id == before.id
    assert after_entry.relative_path == "after.md"
    assert File.read!(Path.join(archives, "after.md")) == "content"
  end

  test "describes a private document with explicit permission bypass", %{
    archives: archives,
    storage_opts: opts
  } do
    File.write!(Path.join(archives, "private.md"), "private")
    {:ok, entry} = file_info("private.md", opts)
    actor = %{skip_permissions: true}
    event = event(%{file_id: entry.id}, opts, actor)

    result = Api.handle_event(event, :describe_document, nil)

    assert_result(event, result, {:ok, %{entry | relative_path: "private.md"}})
    assert {:ok, described} = result.response
    assert described.id == entry.id
    assert described.relative_path == "private.md"
  end

  test "lists document grants", %{archives: archives, storage_opts: opts} do
    File.write!(Path.join(archives, "granted.md"), "granted")
    {:ok, entry} = file_info("granted.md", opts)
    {:ok, person} = People.create_person(%{full_name: "Storage Grant Person"})

    {:ok, permission} =
      Permissions.grant(%StorageEntry{id: entry.id}, %{
        person_id: person.id,
        access_rights: ["read"]
      })

    event = event(%{file_id: entry.id}, opts)

    result = Api.handle_event(event, :list_document_grants, nil)

    expected = %{
      id: permission.id,
      type: "person",
      target_id: to_string(person.id),
      name: person.full_name,
      access_rights: ["read"]
    }

    assert_result(event, result, {:ok, %{permissions: [expected], public?: false}})
  end

  test "searches documents with string actor permission bypass", %{
    archives: archives,
    storage_opts: opts
  } do
    File.write!(Path.join(archives, "unique-search-report.md"), "report")
    actor = %{"skip_permissions" => true}
    event = event(%{params: %{"query" => "unique-search-report"}}, opts, actor)

    result = Api.handle_event(event, :search_documents, nil)

    assert {:ok, %{entries: [entry]}} = result.response
    assert entry.name == "unique-search-report.md"
    assert entry.volume == "archives"
    assert entry.relative_path == "unique-search-report.md"
    assert_result(event, result, result.response)
  end

  test "returns volume stats", %{archives: archives, storage_opts: opts} do
    File.mkdir_p!(Path.join(archives, "manuals"))
    File.write!(Path.join(archives, "one.md"), "1")
    File.write!(Path.join(archives, "manuals/two.md"), "2")
    event = event(%{}, opts)

    result = Api.handle_event(event, :volume_stats, nil)

    assert_result(
      event,
      result,
      {:ok, %{files_count: 2, folders_count: 1, principals_count: 0, root_folders: ["archives"]}}
    )
  end

  test "delegates invoke and reports unsupported actions", %{storage_opts: opts} do
    event = event(%{module: String, function: :upcase, args: ["hi"]}, opts)
    result = Api.handle_event(event, :invoke, nil)
    assert_result(event, result, "HI")

    unsupported = event(%{}, opts)
    result = Api.handle_event(unsupported, :unknown_action, nil)
    assert_result(unsupported, result, {:error, {:unsupported_action, :unknown_action}})
  end

  defp event(request, storage_opts, actor \\ nil),
    do: Event.new(request, :storage, opts: storage_opts, actor: actor)

  defp file_info(path, opts), do: Zaq.Storage.file_info("archives", path, opts)

  defp assert_result(event, result, response), do: assert(result == %{event | response: response})
end

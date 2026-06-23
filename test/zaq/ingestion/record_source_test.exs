defmodule Zaq.Ingestion.RecordSourceTest do
  use ExUnit.Case, async: false

  alias Zaq.Contracts.Record
  alias Zaq.Ingestion.RecordSource

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "record_source_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp_dir, "docs"))
    File.write!(Path.join(tmp_dir, "docs/readme.md"), "# Readme")

    previous = Application.get_env(:zaq, Zaq.Ingestion)

    Application.put_env(:zaq, Zaq.Ingestion,
      base_path: tmp_dir,
      volumes: %{"docs" => Path.join(tmp_dir, "docs")}
    )

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.Ingestion, previous || [])
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "normalizes record kinds and resolves paths from volume attributes", %{tmp_dir: tmp_dir} do
    record = %Record{
      id: "r1",
      kind: "directory",
      attributes: %{"volume" => "docs", "relative_path" => "readme.md"}
    }

    assert RecordSource.kind(record) == :folder
    assert RecordSource.volume(record) == "docs"
    assert RecordSource.relative_path(record) == "readme.md"
    assert RecordSource.resolve_path(record) == {:ok, Path.join([tmp_dir, "docs", "readme.md"])}
  end

  test "falls back to atom attributes, record path, and unsupported source errors" do
    atom_attrs = %Record{id: "r2", kind: :file, attributes: %{relative_path: "docs/readme.md"}}
    assert RecordSource.relative_path(atom_attrs) == "docs/readme.md"
    assert {:ok, _path} = RecordSource.resolve_path(atom_attrs)

    path_record = %Record{id: "r3", kind: :file, path: "docs/readme.md", attributes: nil}
    assert RecordSource.relative_path(path_record) == "docs/readme.md"

    unsupported = %Record{id: "r4", kind: :file, attributes: %{}}
    assert RecordSource.resolve_path(unsupported) == {:error, :unsupported_record_source}
  end

  test "lists folder children with local-volume record attributes" do
    record = %Record{
      id: "folder",
      kind: :folder,
      attributes: %{"volume" => "docs", "relative_path" => "."}
    }

    assert {:ok, [child]} = RecordSource.list_children(record)
    assert child.name == "readme.md"
    assert child.kind == :file
    assert child.attributes["volume"] == "docs"
    assert child.attributes["relative_path"] == "readme.md"
  end

  test "lists folder children without an explicit volume and returns nil without a path" do
    record = %Record{id: "folder", kind: :folder, path: "docs"}

    assert {:ok, [child]} = RecordSource.list_children(record)
    assert child.name == "readme.md"

    assert RecordSource.list_children(%Record{id: "empty", kind: :folder}) == nil
  end

  test "serializes and deserializes storage maps with datetime fallbacks" do
    datetime = ~U[2026-06-23 06:00:00Z]

    record = %Record{
      id: "r5",
      kind: :directory,
      name: "Docs",
      path: ".",
      mime_type: "inode/directory",
      size: 12,
      modified_at: datetime,
      attributes: %{"volume" => "docs"}
    }

    storage = RecordSource.to_storage_map(record)
    assert storage["kind"] == "directory"
    assert storage["modified_at"] == DateTime.to_iso8601(datetime)

    assert {:ok, decoded} = RecordSource.from_storage_map(storage)
    assert decoded.kind == :folder
    assert decoded.modified_at == datetime

    nil_storage = RecordSource.to_storage_map(%Record{id: "r7", kind: :file, modified_at: nil})
    assert nil_storage["modified_at"] == nil
    assert nil_storage["attributes"] == %{}

    assert {:ok, invalid_datetime} =
             RecordSource.from_storage_map(%{
               "id" => "r6",
               "kind" => "file",
               "modified_at" => "not-a-date"
             })

    assert invalid_datetime.modified_at == "not-a-date"

    assert {:ok, nil_datetime} =
             RecordSource.from_storage_map(%{
               "id" => "r8",
               "kind" => "folder",
               "modified_at" => nil
             })

    assert nil_datetime.kind == :folder
    assert nil_datetime.modified_at == nil

    assert RecordSource.kind(%Record{id: "r9", kind: :file}) == :file
    assert RecordSource.kind(%Record{id: "r10", kind: "file"}) == :file
    assert RecordSource.kind(%Record{id: "r11", kind: :spreadsheet}) == :spreadsheet

    assert RecordSource.from_storage_map(%{"kind" => "file"}) == {:error, :invalid_source_record}
  end
end

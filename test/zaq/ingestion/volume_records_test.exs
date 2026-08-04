defmodule Zaq.Ingestion.VolumeRecordsTest do
  # async: false — these tests mount a volume through Application.put_env; concurrent runs
  # would read each other's configuration.
  use Zaq.DataCase, async: false

  alias Zaq.Contracts.Record
  alias Zaq.Event
  alias Zaq.Ingestion.Document
  alias Zaq.Ingestion.FileExplorer.Entry
  alias Zaq.Ingestion.VolumeRecords

  @volume "archives"

  setup do
    root =
      Path.join(System.tmp_dir!(), "zaq_volume_records_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    original = Application.get_env(:zaq, Zaq.Ingestion)

    Application.put_env(
      :zaq,
      Zaq.Ingestion,
      Keyword.merge(original || [], volumes: %{@volume => root})
    )

    on_exit(fn ->
      File.rm_rf(root)

      if is_nil(original) do
        Application.delete_env(:zaq, Zaq.Ingestion)
      else
        Application.put_env(:zaq, Zaq.Ingestion, original)
      end
    end)

    %{root: root}
  end

  defp file_entry(relative_path, attrs \\ %{}) do
    struct!(
      %Entry{
        name: Path.basename(relative_path),
        type: :file,
        size: 12,
        modified_at: 1_700_000_000,
        volume: @volume,
        relative_path: relative_path
      },
      attrs
    )
  end

  defp dir_entry(relative_path) do
    %Entry{
      name: Path.basename(relative_path),
      type: :directory,
      size: 0,
      modified_at: 1_700_000_000,
      volume: @volume,
      relative_path: relative_path
    }
  end

  defp create_document(source) do
    {:ok, document} = Document.create(%{source: source, content: "content for #{source}"})
    document
  end

  # `to_record/1` maps an already-resolved entry, so these build the resolved fields by hand
  # rather than going through a database lookup.
  defp resolved(%Entry{} = entry, id, source) do
    %{entry | id: id, source: source}
  end

  describe "to_record/1" do
    test "derives the mime type from the extension for files" do
      record =
        "guide.md"
        |> file_entry()
        |> resolved("disk:#{@volume}:guide.md", "guide.md")
        |> VolumeRecords.to_record()

      assert %Record{kind: :file, name: "guide.md", mime_type: "text/markdown"} = record
    end

    test "maps a directory entry onto the record's :folder kind, with no mime type" do
      record =
        "reports"
        |> dir_entry()
        |> resolved("disk:#{@volume}:reports", "reports")
        |> VolumeRecords.to_record()

      assert %Record{kind: :folder, mime_type: nil} = record
    end

    test "carries provider, volume, relative path, and source attributes" do
      entry = resolved(file_entry("manuals/guide.md"), "id-1", "manuals/guide.md")
      record = VolumeRecords.to_record(entry)

      assert record.path == "manuals/guide.md"

      assert record.attributes == %{
               "provider" => "disk",
               "volume" => @volume,
               "relative_path" => "manuals/guide.md",
               "source" => "manuals/guide.md"
             }
    end

    test "keeps size and modified_at from the volume entry" do
      entry =
        "guide.md"
        |> file_entry(%{size: 99, modified_at: 1_712_345_678})
        |> resolved("id-1", "guide.md")

      record = VolumeRecords.to_record(entry)

      assert record.size == 99
      assert record.modified_at == 1_712_345_678
      assert record.raw == %{local_entry: entry}
    end

    test "attaches a materializing event whose file_id is the record id" do
      entry = resolved(file_entry("materializable.md"), "4242", "materializable.md")
      record = VolumeRecords.to_record(entry)

      assert %Event{request: %{file_id: file_id}, opts: opts, next_hop: next_hop} =
               record.materializing_event

      assert file_id == record.id
      assert file_id == "4242"
      assert opts[:action] == :materialize_record
      assert next_hop.destination == :ingestion
    end

    test "leaves folders with no materializing event" do
      record =
        "reports"
        |> dir_entry()
        |> resolved("disk:#{@volume}:reports", "reports")
        |> VolumeRecords.to_record()

      assert record.materializing_event == nil
    end
  end

  describe "from_entries/1" do
    test "resolves ids and converts the listing into records" do
      one = create_document("#{@volume}/one.md")

      records = VolumeRecords.from_entries([file_entry("one.md"), file_entry("two.md")])

      assert Enum.map(records, & &1.id) == [to_string(one.id), "disk:#{@volume}:two.md"]
    end

    test "returns folders alongside files" do
      records = VolumeRecords.from_entries([dir_entry("reports"), file_entry("guide.md")])

      assert Enum.map(records, & &1.kind) == [:folder, :file]
    end

    test "attaches a materializing event to files with no document row" do
      assert [record] = VolumeRecords.from_entries([file_entry("unindexed.md")])

      assert %Event{request: %{file_id: file_id}} = record.materializing_event
      assert file_id == record.id
      assert file_id == "disk:#{@volume}:unindexed.md"
    end

    test "returns an empty list for an empty listing" do
      assert VolumeRecords.from_entries([]) == []
    end
  end

  describe "from_path/2" do
    test "builds a record for a file on the volume", %{root: root} do
      File.write!(Path.join(root, "ondisk.md"), "# on disk")
      document = create_document("#{@volume}/ondisk.md")

      assert {:ok, %Record{} = record} = VolumeRecords.from_path(@volume, "ondisk.md")
      assert record.id == to_string(document.id)
      assert record.name == "ondisk.md"
      assert record.kind == :file
      assert record.mime_type == "text/markdown"
      assert record.content == nil
    end

    test "builds a record for a nested file", %{root: root} do
      File.mkdir_p!(Path.join(root, "manuals"))
      File.write!(Path.join([root, "manuals", "nested.md"]), "# nested")

      assert {:ok, record} = VolumeRecords.from_path(@volume, "manuals/nested.md")
      assert record.path == "manuals/nested.md"
      assert record.id == "disk:#{@volume}:manuals/nested.md"
    end

    test "normalizes a leading ./ before reading", %{root: root} do
      File.write!(Path.join(root, "dotted.md"), "# dotted")

      assert {:ok, record} = VolumeRecords.from_path(@volume, "./dotted.md")
      assert record.path == "dotted.md"
    end

    test "propagates the filesystem error for a missing file" do
      assert {:error, :enoent} = VolumeRecords.from_path(@volume, "gone.md")
    end

    test "with no volume, reads through the volume-less explorer path", %{root: root} do
      # Single-volume callers pass `nil` and a path that still resolves — the record then
      # carries no volume and its source is the bare path it was given.
      File.write!(Path.join(root, "novolume.md"), "# no volume")
      document = create_document("#{@volume}/novolume.md")

      assert {:ok, record} = VolumeRecords.from_path(nil, "#{@volume}/novolume.md")
      assert record.id == to_string(document.id)
      assert record.attributes["volume"] == nil
      assert record.attributes["source"] == "#{@volume}/novolume.md"
    end
  end
end

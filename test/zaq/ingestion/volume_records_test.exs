defmodule Zaq.Ingestion.VolumeRecordsTest do
  # async: false — these tests mount a volume through Application.put_env; concurrent runs
  # would read each other's configuration.
  use Zaq.DataCase, async: false

  alias Zaq.Contracts.Record
  alias Zaq.Event
  alias Zaq.Ingestion.Document
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

  defp file_entry(name, attrs \\ %{}) do
    Map.merge(%{name: name, type: :file, size: 12, modified_at: 1_700_000_000}, attrs)
  end

  defp dir_entry(name) do
    %{name: name, type: :directory, size: 0, modified_at: 1_700_000_000}
  end

  defp create_document(source) do
    {:ok, document} = Document.create(%{source: source, content: "content for #{source}"})
    document
  end

  describe "record_id/3" do
    test "answers with the document id when a row exists for the source" do
      document = create_document("#{@volume}/product.pdf")

      assert VolumeRecords.record_id(@volume, "product.pdf") == to_string(document.id)
    end

    test "falls back to a volume-path id when no document row exists" do
      assert VolumeRecords.record_id(@volume, "unfiled/product.pdf") ==
               "disk:#{@volume}:unfiled/product.pdf"
    end

    test "resolves a document stored under the bare relative path" do
      document = create_document("legacy.md")

      assert VolumeRecords.record_id(@volume, "legacy.md") == to_string(document.id)
    end

    test "resolves a document stored under the volume-prefixed path" do
      document = create_document("#{@volume}/prefixed.md")

      assert VolumeRecords.record_id(@volume, "prefixed.md") == to_string(document.id)
    end

    test "considers only the bare relative path when there is no volume" do
      bare = create_document("nil-volume.md")
      _prefixed = create_document("#{@volume}/nil-volume.md")

      assert VolumeRecords.record_id(nil, "nil-volume.md") == to_string(bare.id)
    end

    test "names the fallback volume 'default' when there is no volume" do
      assert VolumeRecords.record_id(nil, "orphan.md") == "disk:default:orphan.md"
    end

    test "reads the id out of a prepared source map rather than querying" do
      ids = %{"#{@volume}/mapped.md" => 4242}

      assert VolumeRecords.record_id(@volume, "mapped.md", ids) == "4242"
    end

    test "falls back to the path id when the prepared map has no entry" do
      assert VolumeRecords.record_id(@volume, "mapped.md", %{}) == "disk:#{@volume}:mapped.md"
    end
  end

  describe "from_entry/4" do
    test "derives the mime type from the extension for files" do
      record = VolumeRecords.from_entry(file_entry("guide.md"), @volume, ".")

      assert %Record{kind: :file, name: "guide.md", mime_type: "text/markdown"} = record
    end

    test "leaves the mime type nil for folders" do
      record = VolumeRecords.from_entry(dir_entry("reports"), @volume, ".")

      assert %Record{kind: :folder, mime_type: nil} = record
    end

    test "carries provider, volume, relative path, and source attributes" do
      record = VolumeRecords.from_entry(file_entry("guide.md"), @volume, "manuals")

      assert record.path == "manuals/guide.md"

      assert record.attributes == %{
               "provider" => "disk",
               "volume" => @volume,
               "relative_path" => "manuals/guide.md",
               "source" => "manuals/guide.md"
             }
    end

    test "keeps size and modified_at from the volume entry" do
      entry = file_entry("guide.md", %{size: 99, modified_at: 1_712_345_678})
      record = VolumeRecords.from_entry(entry, @volume, ".")

      assert record.size == 99
      assert record.modified_at == 1_712_345_678
      assert record.raw == %{local_entry: entry}
    end

    test "attaches a materializing event whose file_id is the record id" do
      document = create_document("#{@volume}/materializable.md")
      record = VolumeRecords.from_entry(file_entry("materializable.md"), @volume, ".")

      assert %Event{request: %{file_id: file_id}, opts: opts, next_hop: next_hop} =
               record.materializing_event

      assert file_id == record.id
      assert file_id == to_string(document.id)
      assert opts[:action] == :materialize_record
      assert next_hop.destination == :ingestion
    end

    test "attaches a materializing event to files with no document row" do
      record = VolumeRecords.from_entry(file_entry("unindexed.md"), @volume, ".")

      assert %Event{request: %{file_id: file_id}} = record.materializing_event
      assert file_id == record.id
      assert file_id == "disk:#{@volume}:unindexed.md"
    end

    test "leaves folders with no materializing event" do
      record = VolumeRecords.from_entry(dir_entry("reports"), @volume, ".")

      assert record.materializing_event == nil
    end

    test "holds the bare relative path in attributes even when the document is prefixed" do
      # `attributes["source"]` takes the first source candidate, which is the bare relative
      # path, while `Document.source` is volume-prefixed. Nothing looks a document up by this
      # attribute — pinned so it is not turned into a lookup key by accident.
      document = create_document("#{@volume}/divergent.md")
      record = VolumeRecords.from_entry(file_entry("divergent.md"), @volume, ".")

      assert record.attributes["source"] == "divergent.md"
      assert document.source == "#{@volume}/divergent.md"
      assert record.id == to_string(document.id)
    end
  end

  describe "from_entries/3" do
    test "resolves document ids for the whole listing" do
      one = create_document("#{@volume}/one.md")
      two = create_document("#{@volume}/two.md")

      records =
        VolumeRecords.from_entries(
          [file_entry("one.md"), file_entry("two.md"), file_entry("three.md")],
          @volume,
          "."
        )

      assert Enum.map(records, & &1.id) == [
               to_string(one.id),
               to_string(two.id),
               "disk:#{@volume}:three.md"
             ]
    end

    test "issues one document query for the listing, not one per entry" do
      Enum.each(1..5, &create_document("#{@volume}/batch#{&1}.md"))
      entries = Enum.map(1..5, &file_entry("batch#{&1}.md"))

      handler_id = "volume-records-query-count-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:zaq, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if String.contains?(metadata.query, ~s(FROM "documents")) do
            send(test_pid, :document_query)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      VolumeRecords.from_entries(entries, @volume, ".")

      assert_received :document_query
      refute_received :document_query
    end

    test "returns folders alongside files" do
      records =
        VolumeRecords.from_entries([dir_entry("reports"), file_entry("guide.md")], @volume, ".")

      assert Enum.map(records, & &1.kind) == [:folder, :file]
    end

    test "returns an empty list for an empty listing" do
      assert VolumeRecords.from_entries([], @volume, ".") == []
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

  describe "from_entry/4 with no volume" do
    test "uses the bare relative path as the source" do
      record = VolumeRecords.from_entry(file_entry("guide.md"), nil, "manuals")

      assert record.attributes["volume"] == nil
      assert record.attributes["source"] == "manuals/guide.md"
      assert record.id == "disk:default:manuals/guide.md"
    end
  end
end

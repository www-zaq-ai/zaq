defmodule Zaq.Ingestion.VolumeEntriesTest do
  # async: false — these tests mount a volume through Application.put_env; concurrent runs
  # would read each other's configuration.
  use Zaq.DataCase, async: false

  alias Zaq.Ingestion.Document
  alias Zaq.Ingestion.FileExplorer.Entry
  alias Zaq.Ingestion.VolumeEntries

  @volume "archives"

  setup do
    root =
      Path.join(System.tmp_dir!(), "zaq_volume_entries_#{System.unique_integer([:positive])}")

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

  defp file_entry(relative_path, volume \\ @volume) do
    %Entry{
      name: Path.basename(relative_path),
      type: :file,
      size: 12,
      modified_at: 1_700_000_000,
      volume: volume,
      relative_path: relative_path
    }
  end

  defp create_document(source) do
    {:ok, document} = Document.create(%{source: source, content: "content for #{source}"})
    document
  end

  describe "resolve/1 identity" do
    test "answers with the document id when a row exists for the source" do
      document = create_document("#{@volume}/product.pdf")

      assert %Entry{id: id, document_id: document_id} =
               VolumeEntries.resolve(file_entry("product.pdf"))

      assert id == to_string(document.id)
      assert document_id == document.id
    end

    test "falls back to a volume-path id when no document row exists" do
      assert %Entry{id: id, document_id: nil} =
               VolumeEntries.resolve(file_entry("unfiled/product.pdf"))

      assert id == "disk:#{@volume}:unfiled/product.pdf"
    end

    test "resolves a document stored under the bare relative path" do
      document = create_document("legacy.md")

      assert %Entry{id: id} = VolumeEntries.resolve(file_entry("legacy.md"))
      assert id == to_string(document.id)
    end

    test "resolves a document stored under the volume-prefixed path" do
      document = create_document("#{@volume}/prefixed.md")

      assert %Entry{id: id} = VolumeEntries.resolve(file_entry("prefixed.md"))
      assert id == to_string(document.id)
    end

    test "considers only the bare relative path when there is no volume" do
      bare = create_document("nil-volume.md")
      _prefixed = create_document("#{@volume}/nil-volume.md")

      assert %Entry{id: id} = VolumeEntries.resolve(file_entry("nil-volume.md", nil))
      assert id == to_string(bare.id)
    end

    test "names the fallback volume 'default' when there is no volume" do
      assert %Entry{id: "disk:default:orphan.md"} =
               VolumeEntries.resolve(file_entry("orphan.md", nil))
    end
  end

  describe "resolve/1 paths" do
    test "normalizes a leading ./ on the relative path" do
      assert %Entry{relative_path: "dotted.md"} =
               VolumeEntries.resolve(file_entry("./dotted.md"))
    end

    test "takes the source from the first candidate, which is the bare relative path" do
      # `Document.source` is volume-prefixed while the entry source is bare. Nothing looks a
      # document up by `source` — pinned so it is not turned into a lookup key by accident.
      document = create_document("#{@volume}/divergent.md")

      assert %Entry{source: source, id: id} = VolumeEntries.resolve(file_entry("divergent.md"))
      assert source == "divergent.md"
      assert document.source == "#{@volume}/divergent.md"
      assert id == to_string(document.id)
    end

    test "uses the bare relative path as the source when there is no volume" do
      assert %Entry{source: "manuals/guide.md", volume: nil} =
               VolumeEntries.resolve(file_entry("manuals/guide.md", nil))
    end

    test "falls back to the entry name when it carries no relative path" do
      entry = %Entry{name: "loose.md", type: :file, volume: @volume}

      assert %Entry{relative_path: "loose.md", source: "loose.md"} = VolumeEntries.resolve(entry)
    end
  end

  describe "resolve/1 over a listing" do
    test "resolves document ids for the whole listing" do
      one = create_document("#{@volume}/one.md")
      two = create_document("#{@volume}/two.md")

      entries =
        VolumeEntries.resolve([
          file_entry("one.md"),
          file_entry("two.md"),
          file_entry("three.md")
        ])

      assert Enum.map(entries, & &1.id) == [
               to_string(one.id),
               to_string(two.id),
               "disk:#{@volume}:three.md"
             ]
    end

    test "issues one document query for the listing, not one per entry" do
      Enum.each(1..5, &create_document("#{@volume}/batch#{&1}.md"))
      entries = Enum.map(1..5, &file_entry("batch#{&1}.md"))

      handler_id = "volume-entries-query-count-#{System.unique_integer([:positive])}"
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

      VolumeEntries.resolve(entries)

      assert_received :document_query
      refute_received :document_query
    end

    test "returns an empty list for an empty listing" do
      assert VolumeEntries.resolve([]) == []
    end
  end

  describe "from_path/2" do
    test "reads an entry off the volume and resolves it", %{root: root} do
      File.write!(Path.join(root, "ondisk.md"), "# on disk")
      document = create_document("#{@volume}/ondisk.md")

      assert {:ok, %Entry{} = entry} = VolumeEntries.from_path(@volume, "ondisk.md")
      assert entry.id == to_string(document.id)
      assert entry.name == "ondisk.md"
      assert entry.type == :file
      assert entry.relative_path == "ondisk.md"
    end

    test "reads a nested file", %{root: root} do
      File.mkdir_p!(Path.join(root, "manuals"))
      File.write!(Path.join([root, "manuals", "nested.md"]), "# nested")

      assert {:ok, entry} = VolumeEntries.from_path(@volume, "manuals/nested.md")
      assert entry.relative_path == "manuals/nested.md"
      assert entry.id == "disk:#{@volume}:manuals/nested.md"
    end

    test "normalizes a leading ./ before reading", %{root: root} do
      File.write!(Path.join(root, "dotted.md"), "# dotted")

      assert {:ok, entry} = VolumeEntries.from_path(@volume, "./dotted.md")
      assert entry.relative_path == "dotted.md"
    end

    test "propagates the filesystem error for a missing file" do
      assert {:error, :enoent} = VolumeEntries.from_path(@volume, "gone.md")
    end

    test "with no volume, reads through the volume-less explorer path", %{root: root} do
      # Single-volume callers pass `nil` and a path that still resolves — the entry then
      # carries no volume and its source is the bare path it was given.
      File.write!(Path.join(root, "novolume.md"), "# no volume")
      document = create_document("#{@volume}/novolume.md")

      assert {:ok, entry} = VolumeEntries.from_path(nil, "#{@volume}/novolume.md")
      assert entry.id == to_string(document.id)
      assert entry.volume == nil
      assert entry.source == "#{@volume}/novolume.md"
    end
  end

  describe "local_provider/0" do
    test "answers with the provider name embedded in fallback ids" do
      assert VolumeEntries.local_provider() == "disk"
    end
  end
end

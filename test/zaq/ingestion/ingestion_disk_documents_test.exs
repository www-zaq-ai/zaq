defmodule Zaq.Ingestion.DiskRecordsTest do
  # async: false — these tests mount volumes through Application.put_env; concurrent runs
  # would read each other's configuration.
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.People
  alias Zaq.Ingestion
  alias Zaq.Ingestion.Chunk
  alias Zaq.Ingestion.Document
  alias Zaq.Repo

  @volume "archives"
  @other_volume "vault"
  @embedding_dimension 768

  setup do
    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "zaq_disk_records_#{unique}")
    other_root = Path.join(System.tmp_dir!(), "zaq_disk_records_other_#{unique}")
    File.mkdir_p!(root)
    File.mkdir_p!(other_root)

    original = Application.get_env(:zaq, Zaq.Ingestion)

    Application.put_env(
      :zaq,
      Zaq.Ingestion,
      Keyword.merge(original || [], volumes: %{@volume => root, @other_volume => other_root})
    )

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(other_root)

      if is_nil(original) do
        Application.delete_env(:zaq, Zaq.Ingestion)
      else
        Application.put_env(:zaq, Zaq.Ingestion, original)
      end
    end)

    %{root: root, other_root: other_root}
  end

  # Writes a file and registers its document row the way an ingest would. Bytes on disk stay
  # separate from `documents.content`, which is a UTF-8 column holding extracted text.
  defp seed_file(root, volume, relative_path, bytes, attrs \\ %{}) do
    absolute = Path.join(root, relative_path)
    absolute |> Path.dirname() |> File.mkdir_p!()
    File.write!(absolute, bytes)

    source = Path.join(volume, relative_path)
    {:ok, document} = Document.create(Map.merge(%{source: source, content: "seeded"}, attrs))

    document
  end

  # A row pointing at a file that is not on the volume — the state most rows in a long-lived
  # install end up in.
  defp seed_stale_row(volume, relative_path) do
    {:ok, document} =
      Document.create(%{source: Path.join(volume, relative_path), content: "orphaned"})

    document
  end

  # Migrations drop `chunks`; `Chunk.create_table/1` provisions it at runtime once an
  # embedding dimension is known. The DDL rolls back with the sandbox transaction.
  defp create_chunks_table do
    Chunk.create_table(@embedding_dimension)
  end

  defp create_person do
    unique = System.unique_integer([:positive])

    {:ok, person} =
      People.create_person(%{
        "full_name" => "Disk Person #{unique}",
        "email" => "disk#{unique}@test.com"
      })

    person
  end

  defp create_team do
    {:ok, team} = People.create_team(%{name: "Disk Team #{System.unique_integer([:positive])}"})
    team
  end

  # ── describe_document/1 ───────────────────────────────────────────────────────

  describe "describe_document/1" do
    test "answers with the entry for a known source", %{root: root} do
      document = seed_file(root, @volume, "guide.md", "# guide")

      assert {:ok, entry} = Ingestion.describe_document(document.source)

      assert entry.id == document.source
      assert entry.name == "guide.md"
      assert entry.type == :file
      assert entry.document_id == document.id
    end

    test "answers for a file that was never ingested", %{root: root} do
      # Reaching a file does not depend on a document row: the source names it on the volume,
      # and the missing row is reported as `document_id: nil` rather than as an error.
      File.write!(Path.join(root, "unindexed.md"), "# unindexed")

      assert {:ok, entry} = Ingestion.describe_document("#{@volume}/unindexed.md")

      assert entry.id == "#{@volume}/unindexed.md"
      assert entry.name == "unindexed.md"
      assert entry.document_id == nil
    end

    test "reports the filesystem error for a source naming no file" do
      assert {:error, :enoent} = Ingestion.describe_document("#{@volume}/gone.md")
    end

    test "finds a row whose source predates volume prefixes", %{root: root} do
      # Legacy rows stored the bare relative path. Both spellings are looked up, so the row
      # is still matched from the volume-prefixed source an entry now carries.
      File.write!(Path.join(root, "legacy.md"), "# legacy")
      {:ok, document} = Document.create(%{source: "legacy.md", content: "seeded"})

      assert {:ok, entry} = Ingestion.describe_document("#{@volume}/legacy.md")
      assert entry.document_id == document.id
    end

    test "reports the filesystem error for a stale row whose file is gone" do
      stale = seed_stale_row(@volume, "deleted.md")

      assert {:error, :enoent} = Ingestion.describe_document(stale.source)
    end

    test "names the entry by its source, not by its document row", %{root: root} do
      document = seed_file(root, @volume, "guide.md", "# guide")

      assert {:ok, entry} = Ingestion.describe_document(document.source)
      assert entry.id == "#{@volume}/guide.md"
      refute entry.id == to_string(document.id)
    end
  end

  # ── list_documents/1 ──────────────────────────────────────────────────────────

  describe "list_documents/1 without a parent filter" do
    test "answers with documents from every mounted volume", %{root: root, other_root: other} do
      archived = seed_file(root, @volume, "guide.md", "# guide")
      vaulted = seed_file(other, @other_volume, "secret.md", "# secret")

      assert {:ok, %{entries: entries}} = Ingestion.list_documents(%{})

      ids = Enum.map(entries, & &1.id)
      assert archived.source in ids
      assert vaulted.source in ids
    end

    test "treats an empty parent filter as no filter", %{root: root} do
      document = seed_file(root, @volume, "guide.md", "# guide")

      assert {:ok, %{entries: entries}} =
               Ingestion.list_documents(%{"filters" => %{"parent" => ""}})

      assert document.source in Enum.map(entries, & &1.id)
    end

    test "drops stale rows and reports the gap in stats", %{root: root} do
      _live = seed_file(root, @volume, "guide.md", "# guide")
      _stale = seed_stale_row(@volume, "deleted.md")

      assert {:ok, %{entries: entries, scanned: scanned}} = Ingestion.list_documents(%{})

      assert scanned == length(entries) + 1
    end

    test "defaults params to an empty map", %{root: root} do
      document = seed_file(root, @volume, "guide.md", "# guide")

      assert {:ok, %{entries: entries}} = Ingestion.list_documents()
      assert document.source in Enum.map(entries, & &1.id)
    end
  end

  describe "list_documents/1 at the volumes root" do
    test "\"/\" lists the volumes themselves, not any one mount's contents", %{root: root} do
      _document = seed_file(root, @volume, "guide.md", "# guide")

      assert {:ok, %{entries: entries, scanned: 2}} =
               Ingestion.list_documents(%{"filters" => %{"parent" => "/"}})

      assert Enum.map(entries, & &1.name) == [@volume, @other_volume] |> Enum.sort()
      assert Enum.all?(entries, &(&1.type == :directory))
    end

    # Each volume root answers with the id `list_documents/1` accepts as a parent, so the BO
    # can drill from the root into a volume without inventing a path.
    test "each volume root is addressable as the next parent", %{root: root} do
      _document = seed_file(root, @volume, "guide.md", "# guide")

      assert {:ok, %{entries: entries}} =
               Ingestion.list_documents(%{"filters" => %{"parent" => "/"}})

      volume_root = Enum.find(entries, &(&1.name == @volume))

      assert {:ok, %{entries: [entry]}} =
               Ingestion.list_documents(%{"filters" => %{"parent" => volume_root.id}})

      assert entry.name == "guide.md"
    end

    # Dropping it would make a volume whose bind failed indistinguishable from one that was
    # never configured. It is listed, and says on itself that it cannot be read.
    test "a volume whose path is gone is still listed, and says so", %{other_root: other_root} do
      File.rm_rf!(other_root)

      assert {:ok, %{entries: entries}} =
               Ingestion.list_documents(%{"filters" => %{"parent" => "/"}})

      assert Enum.map(entries, & &1.name) == [@volume, @other_volume] |> Enum.sort()

      by_name = Map.new(entries, &{&1.name, &1})

      assert by_name[@other_volume].bound == false
      assert by_name[@volume].bound == true
    end
  end

  describe "list_documents/1 with a parent filter" do
    test "a bare volume name lists that volume's root", %{root: root} do
      document = seed_file(root, @volume, "guide.md", "# guide")
      File.mkdir_p!(Path.join(root, "manuals"))

      assert {:ok, %{entries: entries}} =
               Ingestion.list_documents(%{"filters" => %{"parent" => @volume}})

      by_name = Map.new(entries, &{&1.name, &1})
      assert by_name["guide.md"].id == document.source
      assert by_name["manuals"].type == :directory
    end

    test "a subdirectory lists that directory", %{root: root} do
      document = seed_file(root, @volume, "manuals/nested.md", "# nested")

      assert {:ok, %{entries: [entry], scanned: 1}} =
               Ingestion.list_documents(%{"filters" => %{"parent" => "#{@volume}/manuals"}})

      assert entry.id == document.source
      assert entry.relative_path == "manuals/nested.md"
    end

    test "returns folders alongside files, with folders carrying a path id", %{root: root} do
      File.mkdir_p!(Path.join(root, "manuals"))
      _document = seed_file(root, @volume, "guide.md", "# guide")

      assert {:ok, %{entries: entries}} =
               Ingestion.list_documents(%{"filters" => %{"parent" => @volume}})

      folder = Enum.find(entries, &(&1.type == :directory))
      assert folder.id == "#{@volume}/manuals"
      assert folder.document_id == nil
    end

    test "a file with no document row is listed and named by its source", %{root: root} do
      File.write!(Path.join(root, "unindexed.md"), "# unindexed")

      assert {:ok, %{entries: [entry]}} =
               Ingestion.list_documents(%{"filters" => %{"parent" => @volume}})

      assert entry.id == "#{@volume}/unindexed.md"
    end

    test "an unknown volume answers with FileExplorer's error rather than crashing" do
      assert {:error, _reason} =
               Ingestion.list_documents(%{"filters" => %{"parent" => "nosuchvolume/sub"}})
    end

    test "accepts atom-keyed filters", %{root: root} do
      document = seed_file(root, @volume, "guide.md", "# guide")

      assert {:ok, %{entries: entries}} =
               Ingestion.list_documents(%{filters: %{parent: @volume}})

      assert document.source in Enum.map(entries, & &1.id)
    end
  end

  # ── persist_document/1 ────────────────────────────────────────────────────────

  describe "persist_document/1" do
    test "writes the file, registers the row, and names the entry by the row", %{root: root} do
      assert {:ok, %{status: "created", entry: entry}} =
               Ingestion.persist_document(%{
                 "name" => "notes.md",
                 "path" => @volume,
                 "content" => "# notes"
               })

      assert File.read!(Path.join(root, "notes.md")) == "# notes"
      document = Document.get_by_source("#{@volume}/notes.md")
      assert entry.id == document.source
      assert entry.name == "notes.md"
    end

    test "writes into a subdirectory of the volume", %{root: root} do
      File.mkdir_p!(Path.join(root, "manuals"))

      assert {:ok, %{entry: entry}} =
               Ingestion.persist_document(%{
                 "name" => "nested.md",
                 "path" => "#{@volume}/manuals",
                 "content" => "# nested"
               })

      assert File.read!(Path.join([root, "manuals", "nested.md"])) == "# nested"
      assert entry.relative_path == "manuals/nested.md"
    end

    test "deduplicates a name that is already taken", %{root: root} do
      {:ok, _first} =
        Ingestion.persist_document(%{"name" => "hello.md", "path" => @volume, "content" => "one"})

      assert {:ok, %{entry: entry}} =
               Ingestion.persist_document(%{
                 "name" => "hello.md",
                 "path" => @volume,
                 "content" => "two"
               })

      assert entry.name == "hello(1).md"
      assert File.read!(Path.join(root, "hello.md")) == "one"
      assert File.read!(Path.join(root, "hello(1).md")) == "two"
      assert Document.get_by_source("#{@volume}/hello(1).md")
    end

    test "writes raw bytes for base64 content, not the encoded string", %{root: root} do
      bytes = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>

      assert {:ok, %{entry: entry}} =
               Ingestion.persist_document(%{
                 "name" => "logo.png",
                 "path" => @volume,
                 "content" => Base.encode64(bytes),
                 "encoding" => "base64"
               })

      assert File.read!(Path.join(root, "logo.png")) == bytes
      assert entry.name == "logo.png"
    end

    test "refuses malformed base64" do
      assert {:error, :invalid_base64} =
               Ingestion.persist_document(%{
                 "name" => "logo.png",
                 "path" => @volume,
                 "content" => "not base64!!",
                 "encoding" => "base64"
               })
    end

    test "refuses a path that names no mounted volume" do
      assert {:error, :volume_required} =
               Ingestion.persist_document(%{
                 "name" => "notes.md",
                 "path" => "somewhere",
                 "content" => "hi"
               })
    end

    test "refuses a request with no path" do
      assert {:error, :path_required} =
               Ingestion.persist_document(%{"name" => "notes.md", "content" => "hi"})
    end

    test "refuses a request with no name" do
      assert {:error, :name_required} =
               Ingestion.persist_document(%{"path" => @volume, "content" => "hi"})
    end

    test "treats a blank name as absent" do
      assert {:error, :name_required} =
               Ingestion.persist_document(%{"name" => "", "path" => @volume, "content" => "hi"})
    end

    test "defaults missing content to an empty file", %{root: root} do
      assert {:ok, _} = Ingestion.persist_document(%{"name" => "empty.md", "path" => @volume})

      assert File.read!(Path.join(root, "empty.md")) == ""
    end

    test "creating does not ingest — no chunks are produced" do
      create_chunks_table()

      assert {:ok, %{entry: entry}} =
               Ingestion.persist_document(%{
                 "name" => "notes.md",
                 "path" => @volume,
                 "content" => "# notes"
               })

      assert Repo.aggregate(
               from(c in Chunk, where: c.document_id == ^entry.document_id),
               :count
             ) == 0
    end

    test "accepts atom-keyed requests", %{root: root} do
      assert {:ok, %{entry: entry}} =
               Ingestion.persist_document(%{name: "atom.md", path: @volume, content: "# atom"})

      assert entry.name == "atom.md"
      assert File.read!(Path.join(root, "atom.md")) == "# atom"
    end
  end

  # ── update_document/1 ─────────────────────────────────────────────────────────

  describe "update_document/1" do
    test "replaces the bytes in place, leaving the path alone", %{root: root} do
      document = seed_file(root, @volume, "guide.md", "old")

      assert {:ok, %{status: "updated", entry: entry}} =
               Ingestion.update_document(%{
                 "file_id" => document.source,
                 "content" => "new"
               })

      assert File.read!(Path.join(root, "guide.md")) == "new"
      refute File.exists?(Path.join(root, "guide (1).md"))
      assert entry.id == document.source
      assert entry.relative_path == "guide.md"
    end

    test "renames the file and moves the source with it", %{root: root} do
      document = seed_file(root, @volume, "guide.md", "content")

      assert {:ok, %{entry: entry}} =
               Ingestion.update_document(%{
                 "file_id" => document.source,
                 "name" => "renamed.md"
               })

      refute File.exists?(Path.join(root, "guide.md"))
      assert File.read!(Path.join(root, "renamed.md")) == "content"
      # The id is the source, so renaming the file renames the record — the document row is
      # the same row, and its id is what stays stable underneath.
      assert entry.id == "#{@volume}/renamed.md"
      assert entry.name == "renamed.md"
      assert entry.document_id == document.id
      assert Repo.get!(Document, document.id).source == "#{@volume}/renamed.md"
    end

    test "moves the file to another directory in the same volume", %{root: root} do
      document = seed_file(root, @volume, "guide.md", "content")
      File.mkdir_p!(Path.join(root, "manuals"))

      assert {:ok, %{entry: entry}} =
               Ingestion.update_document(%{
                 "file_id" => document.source,
                 "path" => "#{@volume}/manuals"
               })

      refute File.exists?(Path.join(root, "guide.md"))
      assert File.read!(Path.join([root, "manuals", "guide.md"])) == "content"
      assert entry.id == "#{@volume}/manuals/guide.md"
      assert entry.relative_path == "manuals/guide.md"
      assert Repo.get!(Document, document.id).source == "#{@volume}/manuals/guide.md"
    end

    test "writes the new bytes under the new name at the new path", %{root: root} do
      document = seed_file(root, @volume, "guide.md", "old")
      File.mkdir_p!(Path.join(root, "manuals"))

      assert {:ok, %{entry: entry}} =
               Ingestion.update_document(%{
                 "file_id" => document.source,
                 "name" => "renamed.md",
                 "path" => "#{@volume}/manuals",
                 "content" => "new"
               })

      refute File.exists?(Path.join(root, "guide.md"))
      assert File.read!(Path.join([root, "manuals", "renamed.md"])) == "new"
      assert entry.relative_path == "manuals/renamed.md"
    end

    test "an absent content key does not truncate the file", %{root: root} do
      document = seed_file(root, @volume, "guide.md", "keep me")

      assert {:ok, _} =
               Ingestion.update_document(%{
                 "file_id" => document.source,
                 "name" => "renamed.md"
               })

      assert File.read!(Path.join(root, "renamed.md")) == "keep me"
    end

    test "decodes base64 content before writing", %{root: root} do
      document = seed_file(root, @volume, "logo.png", "old")
      bytes = <<0x89, 0x50, 0x4E, 0x47>>

      assert {:ok, _} =
               Ingestion.update_document(%{
                 "file_id" => document.source,
                 "content" => Base.encode64(bytes),
                 "encoding" => "base64"
               })

      assert File.read!(Path.join(root, "logo.png")) == bytes
    end

    test "refuses a move across volumes", %{root: root} do
      document = seed_file(root, @volume, "guide.md", "content")

      assert {:error, :cross_volume_move_unsupported} =
               Ingestion.update_document(%{
                 "file_id" => document.source,
                 "path" => @other_volume
               })

      assert File.exists?(Path.join(root, "guide.md"))
    end

    test "refuses a path that names no mounted volume", %{root: root} do
      document = seed_file(root, @volume, "guide.md", "content")

      assert {:error, :volume_required} =
               Ingestion.update_document(%{
                 "file_id" => document.source,
                 "path" => "somewhere"
               })
    end

    test "refuses an unknown id" do
      assert {:error, :not_found} = Ingestion.update_document(%{"file_id" => "99999999"})
    end

    test "refuses a request with no file_id" do
      assert {:error, :file_id_required} = Ingestion.update_document(%{"name" => "renamed.md"})
    end

    test "a rename with no other change is a no-op move", %{root: root} do
      document = seed_file(root, @volume, "guide.md", "content")

      assert {:ok, %{entry: entry}} =
               Ingestion.update_document(%{
                 "file_id" => document.source,
                 "name" => "guide.md"
               })

      assert entry.relative_path == "guide.md"
      assert File.read!(Path.join(root, "guide.md")) == "content"
    end

    test "a linked sidecar follows the rename", %{root: root} do
      sidecar_source = "#{@volume}/deck.md"

      document =
        seed_file(root, @volume, "deck.pdf", "%PDF", %{
          metadata: %{"sidecar_source" => sidecar_source}
        })

      _sidecar =
        seed_file(root, @volume, "deck.md", "# deck", %{
          metadata: %{"source_document_source" => "#{@volume}/deck.pdf"}
        })

      assert {:ok, _} =
               Ingestion.update_document(%{
                 "file_id" => document.source,
                 "name" => "slides.pdf"
               })

      assert File.exists?(Path.join(root, "slides.pdf"))
      assert File.exists?(Path.join(root, "slides.md"))
      refute File.exists?(Path.join(root, "deck.md"))
      assert Document.get_by_source("#{@volume}/slides.md")
      assert Repo.get!(Document, document.id).metadata["sidecar_source"] == "#{@volume}/slides.md"
    end
  end

  # ── delete_document/1 ─────────────────────────────────────────────────────────

  describe "delete_document/1" do
    test "removes the row, the file, and the chunks", %{root: root} do
      create_chunks_table()

      document = seed_file(root, @volume, "guide.md", "# guide")

      %Chunk{}
      |> Chunk.changeset(%{
        document_id: document.id,
        content: "chunk",
        chunk_index: 0,
        source: document.source
      })
      |> Repo.insert!()

      assert {:ok, %{status: "deleted"}} = Ingestion.delete_document(document.source)

      refute File.exists?(Path.join(root, "guide.md"))
      assert Repo.get(Document, document.id) == nil

      assert Repo.aggregate(from(c in Chunk, where: c.document_id == ^document.id), :count) == 0
    end

    test "answers with the status alone, describing nothing that is gone", %{root: root} do
      # The file is off the volume by the time this returns, so there is nothing left to
      # read — the same answer `JidoConnectBridge.delete_file/2` gives.
      document = seed_file(root, @volume, "guide.md", "# guide")

      assert {:ok, result} = Ingestion.delete_document(document.source)
      assert result == %{status: "deleted"}
    end

    test "refuses a source with no document row" do
      # Deleting is one of the actions that genuinely needs the row — there are chunks and
      # sidecars hanging off it — so an un-ingested file is refused rather than unlinked.
      assert {:error, :not_found} = Ingestion.delete_document("#{@volume}/never-ingested.md")
    end

    test "on a stale row the row still goes but the call reports :enoent" do
      # Pinned as-is: the row is removed before the filesystem delete is attempted, so a row
      # whose file is already gone reports the filesystem error while still being cleaned up.
      document = seed_stale_row(@volume, "deleted.md")

      assert {:error, :enoent} = Ingestion.delete_document(document.source)
      assert Repo.get(Document, document.id) == nil
    end
  end

  # ── materialize_record/1 ────────────────────────────────────────────────────

  describe "materialize_record/1" do
    test "returns markdown as a plain string with no encoding", %{root: root} do
      document = seed_file(root, @volume, "guide.md", "# guide")

      assert {:ok, answer} = Ingestion.materialize_record(%{"file_id" => document.source})

      assert answer == %{content: "# guide", encoding: nil}
    end

    test "answers with the bytes alone, never a record", %{root: root} do
      # Shaping a record is the bridge's job — the dispatching caller already holds the one it
      # built, so rebuilding here would mean two record shapes for one file.
      document = seed_file(root, @volume, "guide.md", "# guide")

      assert {:ok, answer} = Ingestion.materialize_record(%{"file_id" => document.source})

      refute Map.has_key?(answer, :record)
      assert Map.keys(answer) |> Enum.sort() == [:content, :encoding]
    end

    test "returns a pdf base64-encoded, decoding back to the original bytes", %{root: root} do
      bytes = <<0x25, 0x50, 0x44, 0x46, 0x00, 0xFF>>
      document = seed_file(root, @volume, "deck.pdf", bytes)

      assert {:ok, %{content: content, encoding: "base64"}} =
               Ingestion.materialize_record(%{"file_id" => document.source})

      assert Base.decode64!(content) == bytes
    end

    test "an explicit base64 encoding forces encoding for a text file", %{root: root} do
      document = seed_file(root, @volume, "guide.md", "# guide")

      assert {:ok, %{content: content, encoding: "base64"}} =
               Ingestion.materialize_record(%{
                 "file_id" => document.source,
                 "encoding" => "base64"
               })

      assert Base.decode64!(content) == "# guide"
    end

    test "a markdown file holding invalid UTF-8 falls back to base64", %{root: root} do
      bytes = <<0xFF, 0xFE, 0x00, 0x41>>
      document = seed_file(root, @volume, "broken.md", bytes)

      assert {:ok, %{content: content, encoding: "base64"}} =
               Ingestion.materialize_record(%{"file_id" => document.source})

      assert Base.decode64!(content) == bytes
    end

    test "returns other textual types as plain strings", %{root: root} do
      for {name, content} <- [
            {"data.json", ~s({"a":1})},
            {"data.xml", "<a>1</a>"},
            {"data.csv", "a,b\n1,2"},
            {"notes.txt", "plain"}
          ] do
        document = seed_file(root, @volume, name, content)

        assert {:ok, answer} = Ingestion.materialize_record(%{"file_id" => document.source})

        assert answer.content == content, "expected #{name} to come back as text"
        assert answer.encoding == nil
      end
    end

    test "reports the filesystem error for a source naming no file" do
      assert {:error, :enoent} = Ingestion.materialize_record(%{"file_id" => "99999999"})
    end

    test "refuses a request with no file_id" do
      assert {:error, :file_id_required} = Ingestion.materialize_record(%{})
    end

    test "reports :enoent for a stale row" do
      document = seed_stale_row(@volume, "deleted.md")

      assert {:error, :enoent} =
               Ingestion.materialize_record(%{"file_id" => document.source})
    end

    test "materializes a file that was never ingested", %{root: root} do
      # The whole point of naming a record by its source: the bytes are reachable with no
      # document row anywhere in the way.
      File.write!(Path.join(root, "unindexed.md"), "# never ingested")

      assert {:ok, %{content: "# never ingested", encoding: nil}} =
               Ingestion.materialize_record(%{"file_id" => "#{@volume}/unindexed.md"})
    end

    test "reports :enoent for a source naming no file" do
      assert {:error, :enoent} =
               Ingestion.materialize_record(%{"file_id" => "#{@volume}/gone.md"})
    end
  end

  # ── search_documents/1 ────────────────────────────────────────────────────────

  describe "search_documents/1" do
    test "matches on the document source", %{root: root} do
      document = seed_file(root, @volume, "quarterly-report.md", "# report")
      _other = seed_file(root, @volume, "guide.md", "# guide")

      assert {:ok, %{entries: entries}} =
               Ingestion.search_documents(%{"query" => "quarterly"})

      assert Enum.map(entries, & &1.id) == [document.source]
    end

    test "matches on the document title", %{root: root} do
      document = seed_file(root, @volume, "a.md", "# a", %{title: "Annual Budget"})
      _other = seed_file(root, @volume, "b.md", "# b", %{title: "Something Else"})

      assert {:ok, %{entries: entries}} =
               Ingestion.search_documents(%{"query" => "Budget"})

      assert Enum.map(entries, & &1.id) == [document.source]
    end

    test "matches case-insensitively", %{root: root} do
      document = seed_file(root, @volume, "Quarterly.md", "# report")

      assert {:ok, %{entries: [entry]}} =
               Ingestion.search_documents(%{"query" => "QUARTERLY"})

      assert entry.id == document.source
    end

    test "excludes chunk and sidecar rows", %{root: root} do
      document = seed_file(root, @volume, "deck.pdf", "%PDF")

      _sidecar =
        seed_file(root, @volume, "deck.md", "# deck", %{
          metadata: %{"source_document_source" => "#{@volume}/deck.pdf"}
        })

      assert {:ok, %{entries: entries}} = Ingestion.search_documents(%{"query" => "deck"})

      assert Enum.map(entries, & &1.id) == [document.source]
    end

    test "refuses a request with no query" do
      assert {:error, :query_required} = Ingestion.search_documents(%{})
      assert {:error, :query_required} = Ingestion.search_documents(%{"query" => ""})
    end

    test "answers with an empty page when nothing matches" do
      assert {:ok, %{entries: [], scanned: 0}} =
               Ingestion.search_documents(%{"query" => "nothing-matches-this"})
    end

    test "caps the page at 100 rows", %{root: root} do
      Enum.each(1..105, fn index ->
        seed_file(root, @volume, "capped-#{index}.md", "# #{index}")
      end)

      assert {:ok, %{entries: entries, scanned: 100}} =
               Ingestion.search_documents(%{"query" => "capped-"})

      assert length(entries) == 100
    end
  end

  # ── list_document_grants/1 ───────────────────────────────────────────────

  describe "list_document_grants/1" do
    test "reports a person grant with the person's full name", %{root: root} do
      # Grants come back flattened, not as `DocumentPermission` structs — the bridge shaping
      # them into records must not reach into an Ecto schema or its preloads.
      document = seed_file(root, @volume, "guide.md", "# guide")
      person = create_person()

      {:ok, permission} =
        Ingestion.set_document_permission(document.id, :person, person.id, ["read"])

      assert {:ok, %{permissions: [grant], public?: false}} =
               Ingestion.list_document_grants(document.source)

      assert grant == %{
               id: to_string(permission.id),
               type: "person",
               target_id: to_string(person.id),
               name: person.full_name,
               access_rights: ["read"]
             }
    end

    # `permission_target/1`'s `full_name || email` fallback and `{"unknown", nil, nil}` clause
    # are left uncovered: NOT NULL and `check_person_or_team_present` forbid both states.
    test "reports grants for a document with several kinds at once", %{root: root} do
      document = seed_file(root, @volume, "guide.md", "# guide", %{tags: ["public"]})
      person = create_person()
      team = create_team()
      {:ok, _} = Ingestion.set_document_permission(document.id, :person, person.id, ["read"])
      {:ok, _} = Ingestion.set_document_permission(document.id, :team, team.id, ["read"])

      assert {:ok, %{permissions: grants, public?: true}} =
               Ingestion.list_document_grants(document.source)

      assert Enum.sort(Enum.map(grants, & &1.type)) == ["person", "team"]
    end

    test "reports a team grant", %{root: root} do
      document = seed_file(root, @volume, "guide.md", "# guide")
      team = create_team()
      {:ok, _} = Ingestion.set_document_permission(document.id, :team, team.id, ["read", "write"])

      assert {:ok, %{permissions: [grant]}} =
               Ingestion.list_document_grants(document.source)

      assert grant.name == team.name
      assert grant.type == "team"
      assert grant.target_id == to_string(team.id)
      assert grant.access_rights == ["read", "write"]
    end

    test "reports the public tag as a flag, with no grant row behind it", %{root: root} do
      # Public access has no `resource_permissions` row. Ingestion reports the tag and the
      # bridge synthesizes the grant record, so nothing here invents an id.
      document = seed_file(root, @volume, "guide.md", "# guide", %{tags: ["public"]})

      assert {:ok, %{permissions: [], public?: true}} =
               Ingestion.list_document_grants(document.source)
    end

    test "reports the public tag alongside an explicit grant", %{root: root} do
      document = seed_file(root, @volume, "guide.md", "# guide", %{tags: ["public"]})
      person = create_person()
      {:ok, _} = Ingestion.set_document_permission(document.id, :person, person.id, ["read"])

      assert {:ok, %{permissions: [grant], public?: true}} =
               Ingestion.list_document_grants(document.source)

      assert grant.type == "person"
    end

    test "answers with no grants when nobody has access", %{root: root} do
      document = seed_file(root, @volume, "guide.md", "# guide")

      assert {:ok, %{permissions: [], public?: false}} =
               Ingestion.list_document_grants(document.source)
    end

    test "refuses an unknown id" do
      assert {:error, :not_found} = Ingestion.list_document_grants("99999999")
    end

    test "answers for a stale row, since permissions do not need the file" do
      document = seed_stale_row(@volume, "deleted.md")

      assert {:ok, %{permissions: []}} =
               Ingestion.list_document_grants(document.source)
    end
  end

  # ── volume_stats/0 ──────────────────────────────────────────────────────────

  describe "volume_stats/0" do
    test "counts files, excluding chunk and sidecar rows", %{root: root} do
      _document = seed_file(root, @volume, "deck.pdf", "%PDF")

      _sidecar =
        seed_file(root, @volume, "deck.md", "# deck", %{
          metadata: %{"source_document_source" => "#{@volume}/deck.pdf"}
        })

      assert {:ok, %{files_count: 1}} = Ingestion.volume_stats()
    end

    test "counts directories holding at least one document", %{root: root} do
      seed_file(root, @volume, "manuals/one.md", "# one")
      seed_file(root, @volume, "manuals/two.md", "# two")
      seed_file(root, @volume, "reports/three.md", "# three")

      assert {:ok, %{folders_count: 2}} = Ingestion.volume_stats()
    end

    test "counts distinct principals across documents", %{root: root} do
      one = seed_file(root, @volume, "one.md", "# one")
      two = seed_file(root, @volume, "two.md", "# two")
      person = create_person()
      team = create_team()

      {:ok, _} = Ingestion.set_document_permission(one.id, :person, person.id, ["read"])
      {:ok, _} = Ingestion.set_document_permission(two.id, :person, person.id, ["read"])
      {:ok, _} = Ingestion.set_document_permission(two.id, :team, team.id, ["read"])

      assert {:ok, %{principals_count: 2}} = Ingestion.volume_stats()
    end

    test "a public tag adds no principal", %{root: root} do
      seed_file(root, @volume, "one.md", "# one", %{tags: ["public"]})

      assert {:ok, %{principals_count: 0}} = Ingestion.volume_stats()
    end

    test "reports the mounted volume names, sorted" do
      assert {:ok, %{root_folders: [@volume, @other_volume]}} = Ingestion.volume_stats()
    end
  end
end

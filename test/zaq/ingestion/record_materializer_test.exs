defmodule Zaq.Ingestion.RecordMaterializerTest do
  @moduledoc """
  Real filesystem, real database, real `DocumentAccess` — no seams.

  The permission rail here is the one thing standing between an agent and every private
  document in the company, so it is exercised against the real query, not a double.
  """

  use Zaq.DataCase, async: false

  alias Zaq.Accounts.People
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.RecordPage
  alias Zaq.Ingestion.Document
  alias Zaq.Ingestion.RecordMaterializer
  alias Zaq.Permissions.DocumentPermission

  @volume "testvol"

  setup do
    root = Path.join(System.tmp_dir!(), "zaq-materializer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    previous = Application.get_env(:zaq, Zaq.Ingestion, [])

    Application.put_env(
      :zaq,
      Zaq.Ingestion,
      Keyword.put(previous, :volumes, %{@volume => root})
    )

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.Ingestion, previous)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp write_file(root, relative, content) do
    full = Path.join(root, relative)
    full |> Path.dirname() |> File.mkdir_p!()
    File.write!(full, content)
    full
  end

  defp create_person do
    unique = System.unique_integer([:positive])

    {:ok, person} =
      People.create_person(%{"full_name" => "Person #{unique}", "email" => "p#{unique}@test.com"})

    person
  end

  defp grant(doc, person) do
    {:ok, permission} =
      %DocumentPermission{}
      |> DocumentPermission.changeset(%{
        resource_id: to_string(doc.id),
        person_id: person.id,
        access_rights: ["read"]
      })
      |> Zaq.Repo.insert()

    permission
  end

  defp document_for(relative, tags) do
    {:ok, doc} = Document.insert_new(%{source: "#{@volume}/#{relative}"})

    {:ok, doc} =
      doc |> Ecto.Changeset.change(tags: tags) |> Zaq.Repo.update()

    doc
  end

  describe "materialize/2 — content" do
    test "returns the bytes of a public document", %{root: root} do
      write_file(root, "refs/pricing.md", "hello bytes")
      doc = document_for("refs/pricing.md", ["public"])

      assert {:ok, %Record{} = record} =
               RecordMaterializer.materialize(%{file_id: doc.id, person_id: nil})

      assert record.content == "hello bytes"
      assert record.id == to_string(doc.id)
      assert record.name == "pricing.md"
    end

    test "accepts a string file_id", %{root: root} do
      write_file(root, "refs/a.md", "x")
      doc = document_for("refs/a.md", ["public"])

      assert {:ok, %Record{content: "x"}} =
               RecordMaterializer.materialize(%{file_id: to_string(doc.id), person_id: nil})
    end

    # Pairs with D4 in the plan: an empty file is a legitimate result, not a failure and not
    # an "unmaterialized" record.
    test "materializes an empty file to an empty string", %{root: root} do
      write_file(root, "refs/empty.md", "")
      doc = document_for("refs/empty.md", ["public"])

      assert {:ok, %Record{content: ""}} =
               RecordMaterializer.materialize(%{file_id: doc.id, person_id: nil})
    end

    test "returns not_found for an unknown file_id" do
      assert {:error, :not_found} =
               RecordMaterializer.materialize(%{file_id: 999_999_999, person_id: nil})
    end

    test "returns not_found for an unparsable file_id" do
      assert {:error, :not_found} =
               RecordMaterializer.materialize(%{file_id: "not-a-number", person_id: nil})
    end

    test "errors rather than crashing when the row exists but the file is gone" do
      doc = document_for("refs/ghost.md", ["public"])

      assert {:error, {:file_unreadable, :enoent}} =
               RecordMaterializer.materialize(%{file_id: doc.id, person_id: nil})
    end
  end

  describe "materialize/2 — permissions" do
    # The rail from AGENTS.md: a nil person_id is never an implicit grant.
    test "refuses a private document when person_id is nil", %{root: root} do
      write_file(root, "refs/secret.md", "classified")
      doc = document_for("refs/secret.md", [])

      assert {:error, :forbidden} =
               RecordMaterializer.materialize(%{file_id: doc.id, person_id: nil})
    end

    test "refuses a private document for a non-owner person", %{root: root} do
      write_file(root, "refs/secret.md", "classified")
      doc = document_for("refs/secret.md", [])
      owner = create_person()
      stranger = create_person()
      grant(doc, owner)

      assert {:error, :forbidden} =
               RecordMaterializer.materialize(%{file_id: doc.id, person_id: stranger.id})
    end

    test "allows a private document for a permitted person", %{root: root} do
      write_file(root, "refs/secret.md", "classified")
      doc = document_for("refs/secret.md", [])
      owner = create_person()
      grant(doc, owner)

      assert {:ok, %Record{content: "classified"}} =
               RecordMaterializer.materialize(%{file_id: doc.id, person_id: owner.id})
    end

    # There is no skip_permissions option on this path at all — asserted so a future
    # refactor cannot quietly introduce one.
    test "ignores a skip_permissions flag smuggled in via params", %{root: root} do
      write_file(root, "refs/secret.md", "classified")
      doc = document_for("refs/secret.md", [])

      assert {:error, :forbidden} =
               RecordMaterializer.materialize(%{
                 file_id: doc.id,
                 person_id: nil,
                 skip_permissions: true
               })
    end
  end

  describe "describe/2" do
    test "returns unmaterialized records", %{root: root} do
      write_file(root, "refs/a.md", "aaa")
      write_file(root, "refs/b.md", "bbb")
      a = document_for("refs/a.md", ["public"])
      b = document_for("refs/b.md", ["public"])

      assert {:ok, %RecordPage{records: records}} =
               RecordMaterializer.describe(%{file_ids: [a.id, b.id], person_id: nil})

      assert length(records) == 2
      assert Enum.all?(records, &is_nil(&1.content))
      assert Enum.map(records, & &1.name) |> Enum.sort() == ["a.md", "b.md"]
    end

    test "omits ids that no longer exist rather than failing the page", %{root: root} do
      write_file(root, "refs/a.md", "aaa")
      a = document_for("refs/a.md", ["public"])

      assert {:ok, %RecordPage{records: [record]}} =
               RecordMaterializer.describe(%{file_ids: [a.id, 999_999_999], person_id: nil})

      assert record.id == to_string(a.id)
    end

    test "omits documents the caller may not access", %{root: root} do
      write_file(root, "refs/pub.md", "x")
      write_file(root, "refs/priv.md", "y")
      pub = document_for("refs/pub.md", ["public"])
      priv = document_for("refs/priv.md", [])

      assert {:ok, %RecordPage{records: [record]}} =
               RecordMaterializer.describe(%{file_ids: [pub.id, priv.id], person_id: nil})

      assert record.id == to_string(pub.id)
    end

    test "returns an empty page for no ids" do
      assert {:ok, %RecordPage{records: []}} =
               RecordMaterializer.describe(%{file_ids: [], person_id: nil})
    end
  end

  describe "persist/2" do
    test "writes the file, creates the row and applies tags in one call" do
      assert {:ok, %Record{} = record} =
               RecordMaterializer.persist(%{
                 volume: @volume,
                 path: "refs/new.md",
                 content: "fresh",
                 tags: ["public"]
               })

      doc = Document.get(String.to_integer(record.id))
      assert "public" in doc.tags
      assert record.name == "new.md"

      assert {:ok, %Record{content: "fresh"}} =
               RecordMaterializer.materialize(%{file_id: doc.id, person_id: nil})
    end

    test "defaults to no tags, producing a private document" do
      assert {:ok, %Record{} = record} =
               RecordMaterializer.persist(%{volume: @volume, path: "refs/p.md", content: "x"})

      doc = Document.get(String.to_integer(record.id))
      assert doc.tags == []

      assert {:error, :forbidden} =
               RecordMaterializer.materialize(%{file_id: doc.id, person_id: nil})
    end

    # Part 5 depends on the id being stable and non-clobbering: two uploads of the same
    # filename must not overwrite each other, and must not collide on the unique source.
    test "does not clobber an existing file of the same name" do
      opts = %{volume: @volume, path: "refs/dup.md", tags: ["public"]}

      assert {:ok, first} = RecordMaterializer.persist(Map.put(opts, :content, "one"))
      assert {:ok, second} = RecordMaterializer.persist(Map.put(opts, :content, "two"))

      refute first.id == second.id

      assert {:ok, %Record{content: "one"}} =
               RecordMaterializer.materialize(%{file_id: first.id, person_id: nil})

      assert {:ok, %Record{content: "two"}} =
               RecordMaterializer.materialize(%{file_id: second.id, person_id: nil})
    end

    # Re-applying a tag the document already carries must not churn the row.
    test "leaves tags untouched when they are already present" do
      assert {:ok, record} =
               RecordMaterializer.persist(%{
                 volume: @volume,
                 path: "refs/tagged.md",
                 content: "x",
                 tags: ["public", "public"]
               })

      doc = Document.get(String.to_integer(record.id))
      assert doc.tags == ["public"]
    end

    test "rejects a path that escapes the volume" do
      assert {:error, _} =
               RecordMaterializer.persist(%{
                 volume: @volume,
                 path: "../escape.md",
                 content: "nope"
               })
    end
  end

  describe "delete/2" do
    test "removes the document row and the file", %{root: root} do
      write_file(root, "refs/gone.md", "bye")
      doc = document_for("refs/gone.md", ["public"])

      assert :ok = RecordMaterializer.delete(%{file_id: doc.id})
      assert Document.get(doc.id) == nil
      refute File.exists?(Path.join(root, "refs/gone.md"))
    end

    test "is a no-op for an unknown id" do
      assert :ok = RecordMaterializer.delete(%{file_id: 999_999_999})
    end

    # A row whose source no longer maps to any configured volume. The row must still go —
    # leaving it behind would make the document permanently unreadable but still listed.
    test "removes the row even when the path cannot be resolved" do
      {:ok, doc} = Document.insert_new(%{source: "vanished-volume/refs/x.md"})

      assert :ok = RecordMaterializer.delete(%{file_id: doc.id})
      assert Document.get(doc.id) == nil
    end
  end

  describe "single-volume sources" do
    # Legacy shape: no volume prefix on the source, resolved against the configured base
    # path rather than a named volume.
    setup do
      previous = Application.get_env(:zaq, Zaq.Ingestion, [])
      root = Path.join(System.tmp_dir!(), "zaq-legacy-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)

      Application.put_env(:zaq, Zaq.Ingestion, base_path: root, volumes: %{})

      on_exit(fn ->
        Application.put_env(:zaq, Zaq.Ingestion, previous)
        File.rm_rf(root)
      end)

      {:ok, legacy_root: root}
    end

    test "materializes a source with no volume prefix", %{legacy_root: root} do
      File.write!(Path.join(root, "loose.md"), "legacy bytes")
      {:ok, doc} = Document.insert_new(%{source: "loose.md"})
      {:ok, doc} = doc |> Ecto.Changeset.change(tags: ["public"]) |> Zaq.Repo.update()

      assert {:ok, %Record{content: "legacy bytes", name: "loose.md"}} =
               RecordMaterializer.materialize(%{file_id: doc.id, person_id: nil})
    end
  end
end

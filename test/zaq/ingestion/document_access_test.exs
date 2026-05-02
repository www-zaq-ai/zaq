defmodule Zaq.Ingestion.DocumentAccessTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.People
  alias Zaq.Ingestion
  alias Zaq.Ingestion.{Document, DocumentAccess}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_person do
    unique = System.unique_integer([:positive])

    {:ok, person} =
      People.create_person(%{
        "full_name" => "Test Person #{unique}",
        "email" => "person#{unique}@test.com"
      })

    person
  end

  defp create_team do
    {:ok, team} =
      People.create_team(%{name: "Team #{System.unique_integer([:positive])}"})

    team
  end

  defp create_doc(source, metadata \\ %{}) do
    {:ok, doc} =
      Document.create(%{source: source, content: "content for #{source}", metadata: metadata})

    doc
  end

  defp create_chunk(source) do
    create_doc(source, %{"source_document_source" => "parent.md"})
  end

  defp grant(doc_id, :person, id),
    do: Ingestion.set_document_permission(doc_id, :person, id, ["read"])

  defp grant(doc_id, :team, id),
    do: Ingestion.set_document_permission(doc_id, :team, id, ["read"])

  defp uid(label), do: "#{label}-#{System.unique_integer([:positive])}.md"

  # ---------------------------------------------------------------------------
  # list_permitted_document_ids/3
  # ---------------------------------------------------------------------------

  describe "list_permitted_document_ids/3" do
    test "includes doc when person has explicit permission" do
      doc = create_doc(uid("person-perm"))
      person = create_person()
      {:ok, _} = grant(doc.id, :person, person.id)

      result = DocumentAccess.list_permitted_document_ids(person.id, [], [doc.id])
      assert doc.id in result
    end

    test "includes doc when person belongs to a permitted team" do
      doc = create_doc(uid("team-perm"))
      team = create_team()
      person = create_person()
      {:ok, _} = grant(doc.id, :team, team.id)

      result = DocumentAccess.list_permitted_document_ids(person.id, [team.id], [doc.id])
      assert doc.id in result
    end

    test "excludes doc when person has no permission" do
      doc = create_doc(uid("no-perm"))
      person = create_person()

      result = DocumentAccess.list_permitted_document_ids(person.id, [], [doc.id])
      refute doc.id in result
    end

    test "excludes doc when it has permissions but none match" do
      doc = create_doc(uid("wrong-perm"))
      other_person = create_person()
      person = create_person()
      {:ok, _} = grant(doc.id, :person, other_person.id)

      result = DocumentAccess.list_permitted_document_ids(person.id, [], [doc.id])
      refute doc.id in result
    end

    test "includes doc tagged public regardless of permissions" do
      doc = create_doc(uid("pub-tag"))
      {:ok, _} = Ingestion.add_document_tag(doc.id, "public")
      person = create_person()

      result = DocumentAccess.list_permitted_document_ids(person.id, [], [doc.id])
      assert doc.id in result
    end

    test "includes doc tagged public even with mismatched team_ids" do
      doc = create_doc(uid("pub-team"))
      {:ok, _} = Ingestion.add_document_tag(doc.id, "public")
      person = create_person()

      result = DocumentAccess.list_permitted_document_ids(person.id, [-99], [doc.id])
      assert doc.id in result
    end

    test "returns empty when nil person_id and no team_ids" do
      doc = create_doc(uid("nil-person"))
      {:ok, _} = grant(doc.id, :person, create_person().id)

      result = DocumentAccess.list_permitted_document_ids(nil, [], [doc.id])
      assert result == []
    end

    test "handles duplicate doc_ids without duplicating results" do
      doc = create_doc(uid("dup"))
      person = create_person()
      {:ok, _} = grant(doc.id, :person, person.id)

      result = DocumentAccess.list_permitted_document_ids(person.id, [], [doc.id, doc.id, doc.id])
      assert Enum.count(result, &(&1 == doc.id)) == 1
    end

    test "returns mixed results for permitted and denied docs" do
      allowed = create_doc(uid("allowed"))
      denied = create_doc(uid("denied"))
      person = create_person()
      other = create_person()
      {:ok, _} = grant(allowed.id, :person, person.id)
      {:ok, _} = grant(denied.id, :person, other.id)

      result = DocumentAccess.list_permitted_document_ids(person.id, [], [allowed.id, denied.id])
      assert allowed.id in result
      refute denied.id in result
    end
  end

  # ---------------------------------------------------------------------------
  # count_accessible_documents/1
  # ---------------------------------------------------------------------------

  describe "count_accessible_documents/1" do
    test "counts docs with no permission rows (public by default)" do
      _doc = create_doc(uid("open"))
      count = DocumentAccess.count_accessible_documents(person_id: create_person().id)
      assert count >= 1
    end

    test "counts docs with explicit person permission" do
      doc = create_doc(uid("explicit-count"))
      person = create_person()
      other = create_person()
      {:ok, _} = grant(doc.id, :person, other.id)
      # person has no permission — should NOT be counted
      count_before = DocumentAccess.count_accessible_documents(person_id: person.id, team_ids: [])

      {:ok, _} = grant(doc.id, :person, person.id)
      count_after = DocumentAccess.count_accessible_documents(person_id: person.id, team_ids: [])

      assert count_after == count_before + 1
    end

    test "counts docs accessible via team" do
      doc = create_doc(uid("team-count"))
      team = create_team()
      person = create_person()
      other = create_person()
      # lock the doc to other person first so it's no longer public-by-default
      {:ok, _} = grant(doc.id, :person, other.id)

      count_before =
        DocumentAccess.count_accessible_documents(person_id: person.id, team_ids: [team.id])

      {:ok, _} = grant(doc.id, :team, team.id)

      count_after =
        DocumentAccess.count_accessible_documents(person_id: person.id, team_ids: [team.id])

      assert count_after == count_before + 1
    end

    test "counts docs tagged public even without permission row" do
      doc = create_doc(uid("pub-count"))
      person = create_person()
      other = create_person()
      # lock it to someone else first
      {:ok, _} = grant(doc.id, :person, other.id)

      count_before = DocumentAccess.count_accessible_documents(person_id: person.id)
      {:ok, _} = Ingestion.add_document_tag(doc.id, "public")
      count_after = DocumentAccess.count_accessible_documents(person_id: person.id)

      assert count_after == count_before + 1
    end

    test "skip_permissions: true counts all documents including restricted ones" do
      doc = create_doc(uid("admin-count"))
      person = create_person()
      other = create_person()
      {:ok, _} = grant(doc.id, :person, other.id)

      restricted_count = DocumentAccess.count_accessible_documents(person_id: person.id)
      admin_count = DocumentAccess.count_accessible_documents(skip_permissions: true)

      assert admin_count >= restricted_count
      assert admin_count >= 1
    end

    test "excludes chunks (source_document_source metadata present)" do
      _chunk = create_chunk(uid("chunk-excluded"))
      person = create_person()

      count = DocumentAccess.count_accessible_documents(person_id: person.id)
      admin_count = DocumentAccess.count_accessible_documents(skip_permissions: true)

      # Chunks must never appear in either count
      sources_seen =
        DocumentAccess.list_accessible_documents(skip_permissions: true)
        |> Enum.map(& &1.source)

      chunk_sources =
        sources_seen
        |> Enum.filter(fn s -> String.contains?(s, "chunk-excluded") end)

      assert chunk_sources == []
      assert count >= 0
      assert admin_count >= 0
    end

    test "nil person_id with no teams counts only public-by-default docs" do
      _open = create_doc(uid("nil-open"))
      locked = create_doc(uid("nil-locked"))
      {:ok, _} = grant(locked.id, :person, create_person().id)

      # locked doc should not be counted for nil person
      result = DocumentAccess.count_accessible_documents(person_id: nil, team_ids: [])
      assert result >= 1

      # confirm locked doc is not listed
      listed = DocumentAccess.list_accessible_documents(person_id: nil, team_ids: [])
      sources = Enum.map(listed, & &1.source)
      refute locked.source in sources
    end
  end

  # ---------------------------------------------------------------------------
  # list_accessible_documents/1
  # ---------------------------------------------------------------------------

  describe "list_accessible_documents/1" do
    test "returns source and title for accessible docs" do
      doc = create_doc(uid("list-basic"))
      person = create_person()

      result = DocumentAccess.list_accessible_documents(person_id: person.id)
      sources = Enum.map(result, & &1.source)
      assert doc.source in sources
      assert Enum.all?(result, &Map.has_key?(&1, :title))
    end

    test "excludes locked docs the person cannot access" do
      locked = create_doc(uid("list-locked"))
      person = create_person()
      other = create_person()
      {:ok, _} = grant(locked.id, :person, other.id)

      result = DocumentAccess.list_accessible_documents(person_id: person.id)
      sources = Enum.map(result, & &1.source)
      refute locked.source in sources
    end

    test "includes doc after granting person permission" do
      doc = create_doc(uid("list-grant"))
      person = create_person()
      other = create_person()
      {:ok, _} = grant(doc.id, :person, other.id)

      before_grant =
        DocumentAccess.list_accessible_documents(person_id: person.id) |> Enum.map(& &1.source)

      refute doc.source in before_grant

      {:ok, _} = grant(doc.id, :person, person.id)

      after_grant =
        DocumentAccess.list_accessible_documents(person_id: person.id) |> Enum.map(& &1.source)

      assert doc.source in after_grant
    end

    test "includes public-tagged doc for any person" do
      doc = create_doc(uid("list-pub"))
      {:ok, _} = Ingestion.add_document_tag(doc.id, "public")
      other = create_person()
      {:ok, _} = grant(doc.id, :person, other.id)

      stranger = create_person()
      result = DocumentAccess.list_accessible_documents(person_id: stranger.id)
      sources = Enum.map(result, & &1.source)
      assert doc.source in sources
    end

    test "skip_permissions: true returns all top-level docs" do
      doc = create_doc(uid("list-admin"))
      other = create_person()
      {:ok, _} = grant(doc.id, :person, other.id)

      result = DocumentAccess.list_accessible_documents(skip_permissions: true)
      sources = Enum.map(result, & &1.source)
      assert doc.source in sources
    end

    test "results are deduplicated when doc has multiple permission rows" do
      doc = create_doc(uid("list-dedup"))
      person = create_person()
      team = create_team()
      {:ok, _} = grant(doc.id, :person, person.id)
      {:ok, _} = grant(doc.id, :team, team.id)

      result = DocumentAccess.list_accessible_documents(person_id: person.id, team_ids: [team.id])
      sources = Enum.map(result, & &1.source)
      assert Enum.count(sources, &(&1 == doc.source)) == 1
    end

    test "results are sorted by source ascending" do
      p = System.unique_integer([:positive])
      _b = create_doc("zzz-sort-last-#{p}.md")
      _a = create_doc("aaa-sort-first-#{p}.md")

      result = DocumentAccess.list_accessible_documents(skip_permissions: true)
      sources = result |> Enum.map(& &1.source) |> Enum.filter(&String.contains?(&1, "sort"))
      assert sources == Enum.sort(sources)
    end

    test "excludes chunks from listing" do
      _chunk = create_chunk(uid("list-chunk"))
      result = DocumentAccess.list_accessible_documents(skip_permissions: true)
      chunk_entries = Enum.filter(result, fn d -> String.contains?(d.source, "list-chunk") end)
      assert chunk_entries == []
    end
  end

  # ---------------------------------------------------------------------------
  # source_filter support
  # ---------------------------------------------------------------------------

  describe "source_filter — count_accessible_documents/1" do
    test "nil source_filter returns all accessible docs" do
      p = System.unique_integer([:positive])
      _a = create_doc("folder-a-#{p}/doc1.md")
      _b = create_doc("folder-b-#{p}/doc2.md")

      count =
        DocumentAccess.count_accessible_documents(skip_permissions: true, source_filter: nil)

      assert count >= 2
    end

    test "empty source_filter returns all accessible docs" do
      p = System.unique_integer([:positive])
      _a = create_doc("empty-filter-#{p}/doc.md")

      count_all =
        DocumentAccess.count_accessible_documents(skip_permissions: true, source_filter: nil)

      count_filtered =
        DocumentAccess.count_accessible_documents(skip_permissions: true, source_filter: [])

      assert count_filtered == count_all
    end

    test "folder prefix restricts to docs under that folder" do
      p = System.unique_integer([:positive])
      folder = "sf-folder-#{p}"
      _in1 = create_doc("#{folder}/a.md")
      _in2 = create_doc("#{folder}/b.md")
      _out = create_doc("other-folder-#{p}/c.md")

      count =
        DocumentAccess.count_accessible_documents(skip_permissions: true, source_filter: [folder])

      assert count == 2
    end

    test "exact file source_filter matches only that file" do
      p = System.unique_integer([:positive])
      file = "sf-exact-#{p}/target.md"
      _target = create_doc(file)
      _sibling = create_doc("sf-exact-#{p}/other.md")

      count =
        DocumentAccess.count_accessible_documents(skip_permissions: true, source_filter: [file])

      assert count == 1
    end

    test "multiple prefixes in source_filter are OR-ed together" do
      p = System.unique_integer([:positive])
      _a = create_doc("sf-multi-a-#{p}/doc.md")
      _b = create_doc("sf-multi-b-#{p}/doc.md")
      _c = create_doc("sf-multi-c-#{p}/doc.md")

      count =
        DocumentAccess.count_accessible_documents(
          skip_permissions: true,
          source_filter: ["sf-multi-a-#{p}", "sf-multi-b-#{p}"]
        )

      assert count == 2
    end

    test "source_filter combined with permissions — excludes inaccessible docs in folder" do
      p = System.unique_integer([:positive])
      folder = "sf-perm-#{p}"
      open_doc = create_doc("#{folder}/open.md")
      locked_doc = create_doc("#{folder}/locked.md")
      person = create_person()
      other = create_person()
      # lock one doc to someone else
      {:ok, _} = grant(locked_doc.id, :person, other.id)

      count =
        DocumentAccess.count_accessible_documents(
          person_id: person.id,
          source_filter: [folder]
        )

      # open_doc has no permissions (public by default), locked_doc is restricted
      assert count == 1

      listed =
        DocumentAccess.list_accessible_documents(person_id: person.id, source_filter: [folder])

      sources = Enum.map(listed, & &1.source)
      assert open_doc.source in sources
      refute locked_doc.source in sources
    end
  end

  describe "source_filter — list_accessible_documents/1" do
    test "folder prefix restricts listing to that folder" do
      p = System.unique_integer([:positive])
      folder = "sf-list-#{p}"
      in_doc = create_doc("#{folder}/file.md")
      _out_doc = create_doc("other-#{p}/file.md")

      result =
        DocumentAccess.list_accessible_documents(skip_permissions: true, source_filter: [folder])

      sources = Enum.map(result, & &1.source)
      assert in_doc.source in sources
      assert Enum.all?(sources, &String.starts_with?(&1, folder))
    end

    test "exact file source_filter returns only that file" do
      p = System.unique_integer([:positive])
      file = "sf-list-exact-#{p}/target.md"
      _target = create_doc(file)
      _sibling = create_doc("sf-list-exact-#{p}/other.md")

      result =
        DocumentAccess.list_accessible_documents(skip_permissions: true, source_filter: [file])

      assert length(result) == 1
      assert hd(result).source == file
    end
  end
end

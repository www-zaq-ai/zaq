defmodule Zaq.Ingestion.ChunkRefreshTest do
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.People
  alias Zaq.AccountsFixtures
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Ingestion.{Chunk, ChunkRefresh, Document}
  alias Zaq.Permissions

  setup do
    :ok = Chunk.create_table(1536)
  end

  test "replaying setup and an acknowledged-or-not insert retains successes until a newer refresh" do
    user = super_admin()
    source = source_record()
    context = context(user)
    first = Ecto.UUID.generate()
    second = Ecto.UUID.generate()

    assert {:ok, doc} = ChunkRefresh.start(first, source, "First", context)
    assert {:ok, :stored} = ChunkRefresh.insert(first, 1, context, &insert(&1, 1, "first"))
    assert {:ok, :stored} = ChunkRefresh.insert(first, 2, context, &insert(&1, 2, "second"))
    assert {:ok, :already_stored} = ChunkRefresh.insert(first, 1, context, &never_insert/1)

    assert {:ok, %{id: id, content: "First"}} =
             ChunkRefresh.start(first, source, "Retry", context)

    assert id == doc.id
    assert Enum.map(Chunk.list_by_document(id), & &1.content) == ["first", "second"]

    assert {:ok, %{id: ^id}} = ChunkRefresh.start(second, source, "Replacement", context)
    assert {:ok, :stored} = ChunkRefresh.insert(second, 1, context, &insert(&1, 1, "new"))
    assert {:error, :stale_refresh} = ChunkRefresh.start(first, source, "Old", context)
    assert {:error, :stale_refresh} = ChunkRefresh.insert(first, 2, context, &never_insert/1)
    assert [%{content: "new"}] = Chunk.list_by_document(id)
  end

  test "failed inserts do not discard previous chunks and can be retried" do
    user = super_admin()
    source = source_record()
    context = context(user)
    id = Ecto.UUID.generate()

    assert {:ok, doc} = ChunkRefresh.start(id, source, "Markdown", context)
    assert {:ok, :stored} = ChunkRefresh.insert(id, 1, context, &insert(&1, 1, "kept"))

    assert {:error, :invalid_vector} =
             ChunkRefresh.insert(id, 2, context, fn _ -> {:error, :invalid_vector} end)

    assert [%{content: "kept"}] = Chunk.list_by_document(doc.id)
    assert {:ok, :stored} = ChunkRefresh.insert(id, 2, context, &insert(&1, 2, "retried"))
  end

  test "denies missing and non-admin actors, invalid tokens, and handle-only input" do
    source = source_record()
    id = Ecto.UUID.generate()
    admin = super_admin()
    plain_user = AccountsFixtures.user_fixture()

    assert {:error, :unauthorized} = ChunkRefresh.start(id, source, "text", %{})
    assert {:error, :unauthorized} = ChunkRefresh.start(id, source, "text", context(plain_user))

    forged = %{source | provenance_ref: source.provenance_ref <> "tampered"}

    assert {:error, :invalid_source_record} =
             ChunkRefresh.start(id, forged, "text", context(admin))

    handle_only = %{source | provenance_ref: nil, materialization_handle: "read-only"}

    assert {:error, :invalid_source_record} =
             ChunkRefresh.start(id, handle_only, "text", context(admin))

    refute Repo.exists?(Document)
  end

  test "missing permissions leave the existing document, chunks and grants untouched" do
    user = super_admin()
    source = source_record(nil)
    {:ok, doc} = Document.create(%{source: "data_source/google_drive/7/file", content: "Old"})
    assert {:ok, _} = Permissions.grant_public(doc)
    assert {:ok, chunk} = insert(doc, 1, "Old")

    assert {:error, :missing_permission_projection} =
             ChunkRefresh.start(Ecto.UUID.generate(), source, "Replacement", context(user))

    assert Document.get(doc.id).content == "Old"
    assert Chunk.list_by_document(doc.id) == [chunk]
    assert Permissions.public?(doc)
  end

  test "an explicitly empty provider projection removes obsolete indexed grants" do
    user = super_admin()
    fresh_projection = source_record([])
    {:ok, document} = Document.create(%{source: "data_source/google_drive/7/file"})
    assert {:ok, _} = Permissions.grant_public(document)

    assert {:ok, refreshed} =
             ChunkRefresh.start(Ecto.UUID.generate(), fresh_projection, "text", context(user))

    assert refreshed.id == document.id
    refute Permissions.public?(refreshed)
  end

  test "imports the signed Disk grants without treating unsigned fields as ACLs" do
    user = super_admin()

    {:ok, person} =
      People.create_person(%{full_name: "Disk reader", email: "disk-reader@example.org"})

    permission = %Record{
      id: "disk-person",
      kind: :permission,
      attributes: %{
        "type" => "person",
        "target_id" => to_string(person.id),
        "access_rights" => ["read"]
      }
    }

    source = source_record([permission], "disk")

    modified = %{
      source
      | permissions: [%{permission | raw: %{"type" => "public", "access_rights" => ["write"]}}],
        owners: [%{"type" => "public"}]
    }

    assert {:ok, document} =
             ChunkRefresh.start(Ecto.UUID.generate(), modified, "text", context(user))

    assert [%{person_id: person_id, access_rights: ["read"]}] = Permissions.list(document)
    assert person_id == person.id
    refute Permissions.public?(document)
  end

  test "preserves a signed provider reader after the Record crosses a JSON boundary" do
    user = super_admin()
    email = "provider-reader@example.org"

    permission = %Record{
      id: "provider-user",
      kind: :permission,
      attributes: %{
        "principal_type" => "user",
        "principal_key" => email,
        "role" => "reader",
        "access_rights" => ["read"]
      },
      raw: %{"emailAddress" => email}
    }

    source = source_record([permission])
    {:ok, restored} = source |> Jason.encode!() |> Jason.decode!() |> Record.from_map()
    assert {:ok, doc} = ChunkRefresh.start(Ecto.UUID.generate(), restored, "text", context(user))
    assert [%{person_id: person_id, access_rights: ["read"]}] = Permissions.list(doc)
    assert People.get_person(person_id).email == email
  end

  test "a display projection cannot add grants absent from the signed snapshot" do
    user = super_admin()
    source = source_record([])
    forged = %{source | permissions: [public_grant()]}

    assert {:error, :record_provenance_mismatch} = Provenance.verify(forged)
    assert {:ok, doc} = ChunkRefresh.start(Ecto.UUID.generate(), forged, "text", context(user))
    refute Permissions.public?(doc)
  end

  test "a new storage refresh fences old chunk writes and a new full legacy refresh supersedes it" do
    user = super_admin()
    source = source_record()
    id = Ecto.UUID.generate()
    old_request = DateTime.utc_now()
    assert {:ok, doc} = ChunkRefresh.start(id, source, "text", context(user))

    assert {:error, :stale_refresh} =
             ChunkRefresh.legacy_write(doc.id, fn -> flunk("old writes must be fenced") end)

    assert {:error, :stale_refresh} =
             Document.upsert(%{source: doc.source, content: "outdated"}, old_request)

    assert {:ok, newer} = Document.upsert(%{source: doc.source, content: "legacy"})
    assert newer.id == doc.id
    assert {:error, :stale_refresh} = ChunkRefresh.resume(id, context(user))
  end

  test "an attempt cannot be resumed with a different embedding configuration" do
    user = super_admin()
    source = source_record()
    id = Ecto.UUID.generate()
    ctx = Map.put(context(user), :embedding_configuration, %{model: "first", dimension: 16})

    assert {:ok, _doc} = ChunkRefresh.start(id, source, "text", ctx)
    changed = %{ctx | embedding_configuration: %{model: "second", dimension: 16}}
    assert {:error, :embedding_configuration_changed} = ChunkRefresh.resume(id, changed)
  end

  defp context(user), do: %{actor: %{user_id: user.id}}

  defp super_admin, do: AccountsFixtures.super_admin_fixture(%{must_change_password: false})

  defp source_record(permissions \\ [], provider \\ "google_drive") do
    record = %Record{
      id: "file",
      kind: :file,
      name: "original.pdf",
      permissions: permissions,
      attributes: %{"provider" => provider, "config_id" => "7", "provider_record_id" => "file"}
    }

    {:ok, record} =
      Provenance.seal(record, %{
        "provider" => provider,
        "config_id" => 7,
        "source_metadata" => %{"name" => record.name}
      })

    record
  end

  defp public_grant do
    %Record{
      id: "public",
      kind: :permission,
      attributes: %{"type" => "public", "access_rights" => ["read"]}
    }
  end

  defp insert(document, index, content) do
    Chunk.create(%{document_id: document.id, chunk_index: index, content: content})
  end

  defp never_insert(_document), do: flunk("a replay must not insert another chunk")
end

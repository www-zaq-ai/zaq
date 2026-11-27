defmodule Zaq.Ingestion.ChunkRefreshTest do
  use Zaq.DataCase, async: false

  alias Zaq.AccountsFixtures
  alias Zaq.Contracts.{Record, RecordPage}
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Event
  alias Zaq.Ingestion.{Chunk, ChunkRefresh, Document}
  alias Zaq.NodeRouterMock
  alias Zaq.Permissions

  import Mox

  setup :verify_on_exit!

  setup do
    :ok = Chunk.create_table(1536)
  end

  test "replaying setup and an acknowledged-or-not insert retains successes until a newer refresh" do
    user = super_admin()
    source = source_record()
    context = context(user)
    first = Ecto.UUID.generate()
    second = Ecto.UUID.generate()

    expect_source(source)
    assert {:ok, doc} = ChunkRefresh.start(first, source, "First", context)
    assert {:ok, :stored} = ChunkRefresh.insert(first, 1, context, &insert(&1, 1, "first"))
    assert {:ok, :stored} = ChunkRefresh.insert(first, 2, context, &insert(&1, 2, "second"))
    assert {:ok, :already_stored} = ChunkRefresh.insert(first, 1, context, &never_insert/1)

    assert {:ok, %{id: id, content: "First"}} =
             ChunkRefresh.start(first, source, "Retry", context)

    assert id == doc.id
    assert Enum.map(Chunk.list_by_document(id), & &1.content) == ["first", "second"]

    expect_source(source)
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

    expect_source(source)
    assert {:ok, doc} = ChunkRefresh.start(id, source, "Markdown", context)
    assert {:ok, :stored} = ChunkRefresh.insert(id, 1, context, &insert(&1, 1, "kept"))

    assert {:error, :invalid_vector} =
             ChunkRefresh.insert(id, 2, context, fn _ -> {:error, :invalid_vector} end)

    assert [%{content: "kept"}] = Chunk.list_by_document(doc.id)
    assert {:ok, :stored} = ChunkRefresh.insert(id, 2, context, &insert(&1, 2, "retried"))
  end

  test "denies missing and non-admin actors, forged locator fields, and handle-only input" do
    source = source_record()
    id = Ecto.UUID.generate()
    admin = super_admin()
    plain_user = AccountsFixtures.user_fixture()

    assert {:error, :unauthorized} = ChunkRefresh.start(id, source, "text", %{})
    assert {:error, :unauthorized} = ChunkRefresh.start(id, source, "text", context(plain_user))

    forged = %{source | attributes: %{source.attributes | "config_id" => "8"}}

    assert {:error, :invalid_source_record} =
             ChunkRefresh.start(id, forged, "text", context(admin))

    handle_only = %{source | provenance_ref: nil, materialization_handle: "read-only"}

    assert {:error, :invalid_source_record} =
             ChunkRefresh.start(id, handle_only, "text", context(admin))

    refute Repo.exists?(Document)
  end

  test "does not write when the provider cannot return a fresh permission projection" do
    user = super_admin()
    source = source_record(nil)
    expect_source(source)

    assert {:error, :source_unavailable} =
             ChunkRefresh.start(Ecto.UUID.generate(), source, "text", context(user))

    refute Repo.exists?(Document)
  end

  test "uses fresh provider permissions for existing external documents" do
    user = super_admin()
    old_projection = source_record([public_grant()])
    fresh_projection = source_record([])
    {:ok, document} = Document.create(%{source: "data_source/google_drive/7/file"})
    assert {:ok, _} = Permissions.grant_public(document)

    expect_source(fresh_projection)

    assert {:ok, refreshed} =
             ChunkRefresh.start(Ecto.UUID.generate(), old_projection, "text", context(user))

    assert refreshed.id == document.id
    refute Permissions.public?(refreshed)
  end

  test "uses the UI-managed Disk permission projection rather than the passed Record" do
    user = super_admin()
    source = source_record(nil, "disk")
    expect_source(source)

    expect(NodeRouterMock, :dispatch, fn event ->
      assert event.opts[:action] == :data_source_list_permissions
      assert event.request.provider == "disk"

      %{
        event
        | response: {:ok, %RecordPage{resource_type: :permission, records: [public_grant()]}}
      }
    end)

    assert {:ok, document} =
             ChunkRefresh.start(Ecto.UUID.generate(), source, "text", context(user))

    assert Permissions.public?(document)
  end

  test "a new storage refresh fences old chunk writes and a new full legacy refresh supersedes it" do
    user = super_admin()
    source = source_record()
    id = Ecto.UUID.generate()
    old_request = DateTime.utc_now()
    expect_source(source)
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

    expect_source(source)
    assert {:ok, _doc} = ChunkRefresh.start(id, source, "text", ctx)
    changed = %{ctx | embedding_configuration: %{model: "second", dimension: 16}}
    assert {:error, :embedding_configuration_changed} = ChunkRefresh.resume(id, changed)
  end

  defp context(user), do: %{actor: %{user_id: user.id}, node_router: NodeRouterMock}

  defp super_admin, do: AccountsFixtures.super_admin_fixture(%{must_change_password: false})

  defp source_record(permissions \\ [], provider \\ "google_drive") do
    record = %Record{
      id: "file",
      kind: :file,
      name: "original.pdf",
      permissions: permissions,
      attributes: %{"provider" => provider, "config_id" => "7", "provider_record_id" => "file"}
    }

    {:ok, record} = Provenance.seal(record, %{"provider" => provider, "config_id" => 7})
    record
  end

  defp public_grant do
    %Record{
      id: "public",
      kind: :permission,
      attributes: %{"type" => "public", "access_rights" => ["read"]}
    }
  end

  defp expect_source(record) do
    expect(NodeRouterMock, :dispatch, fn %Event{} = event ->
      assert event.opts[:action] == :data_source_get_file
      assert event.request.params["include_permissions"]
      %{event | response: {:ok, %{record: record}}}
    end)
  end

  defp insert(document, index, content) do
    Chunk.create(%{document_id: document.id, chunk_index: index, content: content})
  end

  defp never_insert(_document), do: flunk("a replay must not insert another chunk")
end

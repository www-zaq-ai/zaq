defmodule Zaq.Ingestion.ChunkRefreshConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Mox

  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.AccountsFixtures
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Ingestion.{Chunk, ChunkRefresh, Document}
  alias Zaq.NodeRouterMock
  alias Zaq.Repo

  setup :verify_on_exit!

  test "a committed overlapping insert is cleared by the next refresh and cannot replay" do
    unless independently(&Chunk.table_exists?/0) do
      :ok = independently(fn -> Chunk.create_table(1536) end)
      on_exit(fn -> independently(&Chunk.drop_table/0) end)
    end

    user =
      independently(fn ->
        AccountsFixtures.super_admin_fixture(%{must_change_password: false})
      end)

    first = Ecto.UUID.generate()
    second = Ecto.UUID.generate()
    test_process = self()
    source = source_record(first)
    source_key = "data_source/google_drive/7/#{source.id}"
    ctx = %{actor: %{user_id: user.id}, node_router: NodeRouterMock}

    on_exit(fn ->
      independently(fn ->
        Repo.delete_all(from refresh in ChunkRefresh, where: refresh.id in ^[first, second])

        if document = Document.get_by_source(source_key) do
          Chunk.delete_by_document(document.id)
          Repo.delete!(document)
        end

        Repo.delete!(user)
      end)
    end)

    expect(NodeRouterMock, :dispatch, 2, fn event ->
      assert event.opts[:action] == :data_source_get_file
      if self() != test_process, do: send(test_process, :next_refresh_fetched)
      %{event | response: {:ok, %{record: source}}}
    end)

    assert {:ok, doc} =
             independently(fn -> ChunkRefresh.start(first, source, "Original", ctx) end)

    old_insert =
      Task.async(fn ->
        independently(fn ->
          ChunkRefresh.insert(first, 1, ctx, fn document ->
            send(test_process, :old_insert_holds_lock)
            assert_receive :finish_old_insert, 5_000
            Chunk.create(%{document_id: document.id, chunk_index: 1, content: "original"})
          end)
        end)
      end)

    assert_receive :old_insert_holds_lock, 5_000

    refresh =
      Task.async(fn ->
        independently(fn -> ChunkRefresh.start(second, source, "Replacement", ctx) end)
      end)

    assert_receive :next_refresh_fetched, 5_000
    send(old_insert.pid, :finish_old_insert)
    assert {:ok, :stored} = Task.await(old_insert)
    assert {:ok, %{id: id}} = Task.await(refresh)
    assert id == doc.id

    independently(fn ->
      assert Chunk.list_by_document(id) == []

      assert {:error, :stale_refresh} =
               ChunkRefresh.insert(first, 1, ctx, fn _ ->
                 flunk("obsolete insert callback ran")
               end)
    end)
  end

  defp source_record(id) do
    record = %Record{
      id: id,
      name: "source.pdf",
      kind: :file,
      permissions: [],
      attributes: %{"provider" => "google_drive", "config_id" => "7"}
    }

    {:ok, record} = Provenance.seal(record, %{"provider" => "google_drive", "config_id" => 7})
    record
  end

  defp independently(test), do: Sandbox.unboxed_run(Repo, test)
end

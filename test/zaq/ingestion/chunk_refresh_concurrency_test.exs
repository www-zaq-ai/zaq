defmodule Zaq.Ingestion.ChunkRefreshConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.AccountsFixtures
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Ingestion.{Chunk, ChunkRefresh, Document, DocumentProcessor}
  alias Zaq.Repo

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
    ctx = %{actor: %{user_id: user.id}}

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
        independently(fn ->
          send(test_process, :next_refresh_started)
          ChunkRefresh.start(second, source, "Replacement", ctx)
        end)
      end)

    assert_receive :next_refresh_started, 5_000
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

  test "a committed early reservation fences an overlapping start without deleting indexed chunks" do
    unless independently(&Chunk.table_exists?/0) do
      :ok = independently(fn -> Chunk.create_table(1536) end)
      on_exit(fn -> independently(&Chunk.drop_table/0) end)
    end

    indexed = Ecto.UUID.generate()
    older = Ecto.UUID.generate()
    newer = Ecto.UUID.generate()
    source = source_record(indexed)

    user =
      independently(fn ->
        AccountsFixtures.super_admin_fixture(%{must_change_password: false})
      end)

    context = %{actor: %{user_id: user.id}}
    test_process = self()

    doc =
      independently(fn ->
        {:ok, doc} = ChunkRefresh.start(indexed, source, "Original", context)
        {:ok, _chunk} = Chunk.create(%{document_id: doc.id, chunk_index: 1, content: "Original"})
        {:ok, ^older} = ChunkRefresh.reserve(older, source, context)
        doc
      end)

    on_exit(fn ->
      independently(fn ->
        Repo.delete!(doc)

        Repo.delete_all(
          from attempt in ChunkRefresh, where: attempt.id in ^[indexed, older, newer]
        )

        Repo.delete!(user)
      end)
    end)

    reservation =
      Task.async(fn ->
        independently(fn ->
          Repo.transaction(fn ->
            assert {:ok, ^newer} = ChunkRefresh.reserve(newer, source, context)
            send(test_process, :reservation_holds_lock)
            assert_receive :commit_reservation, 5_000
          end)
        end)
      end)

    assert_receive :reservation_holds_lock, 5_000

    overlapping_start =
      Task.async(fn ->
        independently(fn -> ChunkRefresh.start(older, source, "Delayed", context, older) end)
      end)

    assert independently(fn -> Chunk.count_by_document(doc.id) end) == 1
    send(reservation.pid, :commit_reservation)
    assert {:ok, _} = Task.await(reservation)
    assert {:error, :stale_refresh} = Task.await(overlapping_start)
    assert independently(fn -> Chunk.count_by_document(doc.id) end) == 1
  end

  test "invalidates the language inventory after a visible commit, never on rollback" do
    unless independently(&Chunk.table_exists?/0) do
      :ok = independently(fn -> Chunk.create_table(1536) end)
      on_exit(fn -> independently(&Chunk.drop_table/0) end)
    end

    id = Ecto.UUID.generate()
    replacement_id = Ecto.UUID.generate()
    source = source_record(id)

    user =
      independently(fn ->
        AccountsFixtures.super_admin_fixture(%{must_change_password: false})
      end)

    context = %{actor: %{user_id: user.id}}
    {:ok, doc} = independently(fn -> ChunkRefresh.start(id, source, "Original", context) end)
    test_process = self()
    Phoenix.PubSub.subscribe(Zaq.PubSub, "ingestion:chunk_languages")

    on_exit(fn ->
      independently(fn ->
        Repo.delete!(doc)
        Repo.delete_all(from attempt in ChunkRefresh, where: attempt.id in ^[id, replacement_id])
        Repo.delete!(user)
      end)
    end)

    for outcome <- [:rollback, :commit] do
      writer =
        Task.async(fn ->
          independently(fn ->
            ChunkRefresh.insert(id, 1, context, fn document ->
              {:ok, chunk} =
                DocumentProcessor.insert_precomputed_chunk(
                  document.id,
                  1,
                  "Text",
                  [],
                  %{},
                  List.duplicate(0.1, 1536)
                )

              send(test_process, :inserted_inside_transaction)
              assert_receive :finish_insert, 5_000
              if outcome == :commit, do: {:ok, chunk}, else: {:error, :aborted}
            end)
          end)
        end)

      assert_receive :inserted_inside_transaction, 5_000
      refute_received :chunk_languages_changed
      assert independently(fn -> Chunk.get_by_index(doc.id, 1) end) == nil
      send(writer.pid, :finish_insert)

      case outcome do
        :rollback ->
          assert {:error, :aborted} = Task.await(writer)
          refute_received :chunk_languages_changed
          assert independently(fn -> Chunk.get_by_index(doc.id, 1) end) == nil

        :commit ->
          assert_receive :chunk_languages_changed, 5_000
          assert independently(fn -> Chunk.get_by_index(doc.id, 1) end)
          assert {:ok, :stored} = Task.await(writer)
      end
    end

    replacement =
      Task.async(fn ->
        independently(fn ->
          ChunkRefresh.start(replacement_id, source, "Replacement", context)
        end)
      end)

    assert_receive :chunk_languages_changed, 5_000
    assert independently(fn -> Chunk.get_by_index(doc.id, 1) end) == nil
    assert {:ok, _document} = Task.await(replacement)
  end

  defp source_record(id) do
    record = %Record{
      id: id,
      name: "source.pdf",
      kind: :file,
      permissions: [],
      attributes: %{"provider" => "google_drive", "config_id" => "7"}
    }

    {:ok, record} =
      Provenance.seal(record, %{
        "provider" => "google_drive",
        "config_id" => 7,
        "source_metadata" => %{"name" => record.name}
      })

    record
  end

  defp independently(test), do: Sandbox.unboxed_run(Repo, test)
end

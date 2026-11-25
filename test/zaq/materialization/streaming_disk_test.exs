defmodule Zaq.Materialization.StreamingDiskTest do
  @moduledoc """
  File materialization through the real consumer path (issue #875): handle -> handler ->
  event -> Storage role API -> chunked read -> consumer-owned sink. The router stub only
  chooses the role API; the producer runs in its own process, as it would on another node.
  """
  use Zaq.DataCase, async: false

  alias Zaq.Channels.Materializers.DataSourceDocument
  alias Zaq.Contracts.Record
  alias Zaq.Event
  alias Zaq.Ingestion.RecordSource
  alias Zaq.Materialization
  alias Zaq.Materialization.Sink
  alias Zaq.Storage
  alias Zaq.Storage.Materializers.DiskDocument

  @mib 1024 * 1024

  defmodule Router do
    @moduledoc false
    alias Zaq.Event
    alias Zaq.Storage.Api

    # Runs the destination role API in a separate process. Only the event (which carries the
    # sink pid but never a path) goes in, and only plain response data comes out.
    def dispatch(%Event{next_hop: %{destination: :storage}} = event) do
      test = Process.get(:streaming_test) || self()
      config = Process.get(:storage_config)
      opts = Keyword.merge(event.opts, storage_config: config, stream_chunk_bytes: 64 * 1024)
      event = %{event | opts: opts}
      sink = Keyword.get(event.opts, :materialization_sink)
      send(test, {:storage_event, event.request, sink})
      if is_pid(sink), do: send(test, {:staging_root, :sys.get_state(sink).dir})

      response =
        Task.async(fn -> Api.handle_event(event, opts[:action], nil) end)
        |> Task.await(60_000)

      if is_pid(sink), do: send(test, {:storage_sink_stats, Sink.stats(sink)})
      response
    end

    def dispatch(%Event{next_hop: %{destination: :channels}} = event) do
      handle = Process.get(:nested_handle)

      %{
        event
        | response:
            {:ok,
             %{
               record: %Zaq.Contracts.Record{
                 id: "outer",
                 kind: :file,
                 materialization_handle: handle
               }
             }}
      }
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "streaming_disk_#{System.unique_integer([:positive])}")
    dest = Path.join(System.tmp_dir!(), "streaming_dest_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.mkdir_p!(dest)

    # The volume layout is the event's `storage_config`, set by the Router for this test's
    # process; the application environment is not touched.
    Process.put(:storage_config, base_path: root, volumes: %{"archives" => root})

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(dest)
    end)

    Process.put(:streaming_test, self())
    {:ok, root: root, dest: dest, context: %{node_router: Router, skip_permissions: true}}
  end

  defp entry_handle(root, name, data) do
    path = Path.join(root, name)
    File.write!(path, data)

    {:ok, entry} =
      Storage.file_info("archives", name,
        storage_config: [base_path: root, volumes: %{"archives" => root}],
        skip_permissions: true
      )

    {:ok, handle} = DiskDocument.issue(entry.id)
    {handle, path}
  end

  defp sha(path) do
    path
    |> File.stream!(64 * 1024)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
  end

  describe "invalid acquisition budgets" do
    test "rejects invalid bytes and file quotas before accessing the source", %{
      context: context,
      dest: dest
    } do
      assert {:error, "Disk: invalid materialization quota"} =
               Materialization.materialize(
                 "invalid",
                 Map.put(context, :materialization_max_bytes, -1),
                 "Disk"
               )

      assert {:error, "Disk: invalid materialization quota"} =
               Materialization.materialize_file("invalid", context, "Disk", %{},
                 dir: dest,
                 max_bytes: -1
               )

      assert File.ls!(dest) == []
    end
  end

  describe "materialize_file/5" do
    test "streams a file larger than the old 50 MiB cap under an explicit quota",
         %{root: root, dest: dest, context: context} do
      path = Path.join(root, "big.bin")
      chunk = :crypto.strong_rand_bytes(@mib)

      File.open!(path, [:write, :raw], fn device ->
        for _ <- 1..51, do: :file.write(device, chunk)
      end)

      size = 51 * @mib
      assert File.stat!(path).size > 50 * @mib

      {:ok, entry} =
        Storage.file_info("archives", "big.bin",
          storage_config: [base_path: root, volumes: %{"archives" => root}],
          skip_permissions: true
        )

      {:ok, handle} = DiskDocument.issue(entry.id)

      assert {:ok, %{record: record, file: file}} =
               Materialization.materialize_file(handle, context, "Disk", %{},
                 dir: dest,
                 max_bytes: size
               )

      assert record.content == nil
      assert file.size == size
      assert file.binary?
      assert sha(file.path) == sha(path)
      assert File.exists?(path), "the original is untouched"
      assert_received {:storage_event, request, sink} when is_pid(sink)
      refute inspect(request) =~ dest
    end

    test "accepts exactly the quota and rejects one byte less, leaving nothing behind",
         %{root: root, dest: dest, context: context} do
      {handle, path} = entry_handle(root, "exact.txt", String.duplicate("a", 1000))

      assert {:ok, %{file: %{size: 1000, binary?: false} = file}} =
               Materialization.materialize_file(handle, context, "Disk", %{},
                 dir: dest,
                 max_bytes: 1000
               )

      File.rm!(file.path)

      assert {:error, message} =
               Materialization.materialize_file(handle, context, "Disk", %{},
                 dir: dest,
                 max_bytes: 999
               )

      assert message == "Disk: materialization size limit exceeded (999 bytes)"
      refute message =~ dest
      assert File.ls!(dest) == []
      assert File.read!(path) == String.duplicate("a", 1000)
    end

    test "an oversized file is rejected based on its announced size",
         %{root: root, dest: dest, context: context} do
      {handle, _path} = entry_handle(root, "huge.bin", :binary.copy(<<1>>, 4 * @mib))

      assert {:error, "Disk: materialization size limit exceeded (" <> _} =
               Materialization.materialize_file(handle, context, "Disk", %{},
                 dir: dest,
                 max_bytes: @mib
               )

      assert_receive {:storage_sink_stats,
                      %{size: 0, writes: 0, failure: {:materialization_limit, @mib}}},
                     5_000

      assert File.ls!(dest) == []
    end

    test "producer reads are bounded chunks written one at a time",
         %{root: root} do
      {_handle, _path} = entry_handle(root, "chunks.bin", :binary.copy(<<7>>, 1_000_000))

      {:ok, entry} =
        Storage.file_info("archives", "chunks.bin",
          storage_config: [base_path: root, volumes: %{"archives" => root}],
          skip_permissions: true
        )

      {:ok, sink} = Sink.open(mode: :memory, max_bytes: 2_000_000)

      assert {:ok, %{content: nil}} =
               Storage.materialize_document(%{"file_id" => entry.id},
                 storage_config: [base_path: root, volumes: %{"archives" => root}],
                 skip_permissions: true,
                 materialization_sink: sink,
                 stream_chunk_bytes: 64 * 1024
               )

      assert %{size: 1_000_000, writes: writes, max_chunk: max_chunk} = Sink.stats(sink)
      assert max_chunk <= 64 * 1024
      assert writes == ceil(1_000_000 / (64 * 1024))
    end

    test "text files are reported as text and binary hints survive", %{
      root: root,
      dest: dest,
      context: context
    } do
      {text, _} = entry_handle(root, "note.md", "# héllo")
      {pdf, _} = entry_handle(root, "doc.pdf", "%PDF-1.4 plain ascii")

      assert {:ok, %{file: %{binary?: false}}} =
               Materialization.materialize_file(text, context, "Disk", %{}, dir: dest)

      # A non-textual MIME stays binary even when the bytes happen to be valid UTF-8.
      assert {:ok, %{file: %{binary?: true}}} =
               Materialization.materialize_file(pdf, context, "Disk", %{}, dir: dest)
    end

    test "a denied actor gets no bytes and no file", %{root: root, dest: dest} do
      {handle, _path} = entry_handle(root, "secret.md", "secret")
      denied = %{node_router: Router}

      assert {:error, "Disk: :unauthorized"} =
               Materialization.materialize_file(handle, denied, "Disk", %{}, dir: dest)

      assert_receive {:storage_sink_stats, %{started?: false, size: 0, writes: 0}}, 5_000
      assert File.ls!(dest) == []
    end

    test "an invalid or tampered handle fails before any producer is reached",
         %{dest: dest, context: context} do
      assert {:error, "Disk: " <> _} =
               Materialization.materialize_file("not-a-handle", context, "Disk", %{}, dir: dest)

      refute_received {:storage_event, _, _}
      assert File.ls!(dest) == []
    end

    test "nested handles share one quota", %{root: root, dest: dest, context: context} do
      {disk_handle, _} = entry_handle(root, "nested.bin", :binary.copy(<<9>>, 2_000))
      Process.put(:nested_handle, disk_handle)
      {:ok, outer} = DataSourceDocument.issue(:disk, "outer")

      assert {:ok, %{file: %{size: 2_000}}} =
               Materialization.materialize_file(outer, context, "Nested", %{},
                 dir: dest,
                 max_bytes: 2_000
               )

      assert {:error, "Nested: materialization size limit exceeded (1999 bytes)"} =
               Materialization.materialize_file(outer, context, "Nested", %{},
                 dir: dest,
                 max_bytes: 1_999
               )
    end

    test "a cancelled consumer removes the partial file", %{root: root, dest: dest} do
      {handle, _path} = entry_handle(root, "cancel.bin", :binary.copy(<<3>>, 1_000))

      defmodule HangingRouter do
        @moduledoc false
        def dispatch(%Zaq.Event{opts: opts} = event) do
          sink = Keyword.fetch!(opts, :materialization_sink)
          :ok = Sink.write(sink, "partial bytes")
          send(Process.get(:streaming_test), {:partial, self(), sink})
          Process.sleep(:infinity)
          event
        end
      end

      test = self()

      consumer =
        spawn(fn ->
          Process.put(:streaming_test, test)

          Materialization.materialize_file(handle, %{node_router: HangingRouter}, "Disk", %{},
            dir: dest
          )
        end)

      assert_receive {:partial, ^consumer, sink}
      ref = Process.monitor(sink)
      assert File.ls!(dest) != []

      Process.exit(consumer, :kill)
      assert_receive {:DOWN, ^ref, :process, ^sink, _}
      assert File.ls!(dest) == []
    end
  end

  describe "materialize/4 (bounded bytes API)" do
    test "returns the same record shape as before for text and binary",
         %{root: root, context: context} do
      {text, _} = entry_handle(root, "t.md", "# hi")
      {bin, _} = entry_handle(root, "b.bin", <<0, 1, 2, 255>>)

      assert {:ok, %{record: %Record{content: "# hi", attributes: attrs}}} =
               Materialization.materialize(text, context, "Disk")

      refute Map.has_key?(attrs, "encoding")

      assert {:ok, %{record: %Record{content: content, attributes: %{"encoding" => "base64"}}}} =
               Materialization.materialize(bin, context, "Disk")

      assert Base.decode64!(content) == <<0, 1, 2, 255>>
    end

    test "acquisition stops at the configured cap", %{root: root, context: context} do
      {handle, _} = entry_handle(root, "cap.bin", :binary.copy(<<1>>, 100))

      assert {:ok, _} =
               Materialization.materialize(
                 handle,
                 Map.put(context, :materialization_max_bytes, 100)
               )

      assert {:error, "Materialization failed: materialization size limit exceeded (99 bytes)"} =
               Materialization.materialize(
                 handle,
                 Map.put(context, :materialization_max_bytes, 99)
               )
    end
  end

  describe "ingestion consumer (RecordSource)" do
    defp disk_record(handle, name, mime) do
      %Record{
        id: "disk-1",
        kind: :file,
        name: name,
        mime_type: mime,
        materialization_handle: handle,
        attributes: %{
          "provider" => "disk",
          "config_id" => "cfg",
          "provider_record_id" => "disk-1"
        }
      }
    end

    defp ingestion_context, do: %{node_router: Router, actor: %{skip_permissions: true}}

    test "stages a streamed binary file without a Base64 round trip", %{root: root} do
      data = :crypto.strong_rand_bytes(300_000)
      {handle, source} = entry_handle(root, "scan.pdf", data)
      record = disk_record(handle, "scan.pdf", "application/pdf")

      assert {:ok, %{path: path, cleanup_paths: [staging]}} =
               RecordSource.materialize(record, ingestion_context())

      assert Path.extname(path) == ".pdf"
      assert File.read!(path) == data
      assert File.ls!(staging) == [Path.basename(path)], "no .part file left behind"
      assert File.read!(source) == data
      File.rm_rf!(staging)
    end

    test "stages streamed text as Markdown", %{root: root} do
      {handle, _} = entry_handle(root, "notes.md", "# Title\n\nbody")
      record = disk_record(handle, "notes.md", "text/markdown")

      assert {:ok, %{path: path, cleanup_paths: [staging]}} =
               RecordSource.materialize(record, ingestion_context())

      assert Path.extname(path) == ".md"
      assert File.read!(path) == "# Title\n\nbody"
      File.rm_rf!(staging)
    end

    test "an over-quota source leaves no staging directory behind", %{root: root} do
      {handle, source} = entry_handle(root, "big.pdf", :binary.copy(<<1>>, 5_000))
      record = disk_record(handle, "big.pdf", "application/pdf")

      assert {:error, "Data source document download failed: materialization size limit" <> _} =
               RecordSource.materialize(
                 record,
                 Map.put(ingestion_context(), :materialization_max_bytes, 4_999)
               )

      assert_receive {:staging_root, staging}, 5_000
      refute File.exists?(staging)
      assert File.exists?(source)
    end
  end

  test "events never carry a consumer path", %{root: root, dest: dest, context: context} do
    {handle, _} = entry_handle(root, "p.md", "x")
    assert {:ok, _} = Materialization.materialize_file(handle, context, "Disk", %{}, dir: dest)

    assert_received {:storage_event, request, sink}
    assert is_pid(sink)
    refute inspect(request) =~ Path.basename(dest)
    assert %Event{} = Event.new(%{}, :storage)
  end
end

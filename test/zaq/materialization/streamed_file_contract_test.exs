defmodule Zaq.Materialization.StreamedFileContractTest do
  @moduledoc """
  Contract tests for streamed file materialization (issue #875) that sit across the unit
  tests of `Sink`, the bridge and the disk producer:

    1. the real ingestion consumer (`RecordSource`) streams a Drive body larger than the old
       50 MiB cap into a file under an explicit quota, with no event/record carrying the body;
    2. the Drive client renders JSON arrays as rows while streaming to a file;
    3. a producer on a different BEAM node writes into a consumer-owned sink through a pid in
       event options (two isolated `:peer` nodes with a private cookie);
    4. cleanup after overflow, source failure and owner death, and ownership of a finished
       file.

  No test builds a large binary: bodies are produced by repeating one small chunk and are
  inspected with `File.stat/1` and `:file.pread/3`. The Drive API base URL is application
  environment owned by the dependency, so it is set per call with the process-scoped
  `StreamingDriveClient.with_req_options/2` instead; the bridge module and quotas travel in the
  call's context. The per-test fixture (config, loopback URL, observer) lives in the test
  process and is handed explicitly to any process the test spawns, so no application
  environment or `:persistent_term` key is written. No external network is used (loopback
  only).
  """
  use Zaq.DataCase, async: false

  alias Zaq.Channels.JidoConnectBridge
  alias Zaq.Channels.JidoConnectBridge.StreamingDriveClient
  alias Zaq.Channels.Materializers.DataSourceDocument
  alias Zaq.Contracts.Record
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Connect
  alias Zaq.Event
  alias Zaq.Ingestion.RecordSource
  alias Zaq.Materialization
  alias Zaq.Materialization.Sink
  alias Zaq.Repo

  @kib 1024
  @mib 1024 * 1024
  @chunk 64 * @kib
  # 52 MiB: over the legacy 50 MiB bytes-API cap, built from 64 KiB chunks.
  @big_chunks 52 * 16
  @big_size @big_chunks * @chunk
  @json_ws_chunks 51 * 16
  @json_size @json_ws_chunks * @chunk + 2
  # Each repeated JSON row is 1009 bytes; rendered Markdown rows are 1005 bytes.
  # The header is 13 bytes and the final row is 8 bytes. The test checks literal
  # output at both ends as well as these sizes and the number of sink writes.
  @rows 832 * 64 + 1
  @rows_json_size 1 + 832 * 64 * 1009 + byte_size(~s({"a":"end"})) + 1
  @rows_table_size 13 + 832 * 64 * 1005 + 8

  defmodule DriveServer do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    # 52 MiB binary body without a content-length.
    def call(%{path_info: ["drive", "v3", "files", "big-pdf"]} = conn, _opts) do
      conn = send_chunked(put_resp_content_type(conn, "application/pdf"), 200)
      repeat(conn, 52 * 16, :binary.copy(<<0, 1, 2, 3>>, 16 * 1024))
    end

    # 51 MiB of JSON whitespace and then `[]`: a valid JSON array that Req would decode.
    def call(%{path_info: ["drive", "v3", "files", "json-ws"]} = conn, _opts) do
      conn = send_chunked(put_resp_content_type(conn, "application/json"), 200)
      conn = repeat(conn, 51 * 16, :binary.copy(" ", 64 * 1024))
      {:ok, conn} = chunk(conn, "[]")
      conn
    end

    # 53,249 rows, ~51.2 MiB of JSON, in whole-row chunks.
    def call(%{path_info: ["drive", "v3", "files", "json-big-rows"]} = conn, _opts) do
      conn = send_chunked(put_resp_content_type(conn, "application/json"), 200)
      {:ok, conn} = chunk(conn, "[")
      row = ~s({"a":"#{String.duplicate("x", 1000)}"},)
      conn = repeat(conn, 832, String.duplicate(row, 64))
      {:ok, conn} = chunk(conn, ~s({"a":"end"}]))
      conn
    end

    def call(%{path_info: ["drive", "v3", "files", "json-rows"]} = conn, _opts),
      do:
        conn |> put_resp_content_type("application/json") |> send_resp(200, ~s([{"a":1},{"a":2}]))

    # Never ends: the test acts mid-stream.
    def call(%{path_info: ["drive", "v3", "files", "endless"]} = conn, _opts) do
      conn = send_chunked(put_resp_content_type(conn, "application/pdf"), 200)
      endless(conn, 0)
    end

    # Starts a chunked body and then crashes the handler: the connection drops mid-body.
    def call(%{path_info: ["drive", "v3", "files", "aborts"]} = conn, _opts) do
      conn = send_chunked(put_resp_content_type(conn, "application/pdf"), 200)
      conn = repeat(conn, 8, :binary.copy(<<9>>, 16 * 1024))
      Process.exit(self(), :kill)
      conn
    end

    def call(conn, _opts), do: send_resp(conn, 404, ~s({"error":{"message":"missing"}}))

    defp repeat(conn, 0, _data), do: conn

    defp repeat(conn, n, data) do
      case chunk(conn, data) do
        {:ok, conn} -> repeat(conn, n - 1, data)
        {:error, _closed} -> conn
      end
    end

    defp endless(conn, sent) do
      case chunk(conn, :binary.copy(<<5>>, 16 * 1024)) do
        {:ok, conn} -> endless(conn, sent + 1)
        {:error, _closed} -> conn
      end
    end
  end

  defmodule DriveBridge do
    @moduledoc false
    # Stands in for the DataSourceBridge dispatcher: resolves the config, calls the real bridge.
    alias Zaq.Channels.JidoConnectBridge

    def download_document(_provider, %{materialization_sink: sink} = params, _context)
        when is_pid(sink) do
      %{config: config, req_options: req_options} = Process.get(:drive_fixture)

      StreamingDriveClient.with_req_options(req_options, fn ->
        JidoConnectBridge.download_document(config, params)
      end)
    end
  end

  defmodule Router do
    @moduledoc false
    # Runs the real Channels role API in a separate process (as a remote producer would run),
    # measures what crosses the hop and reports the sink pid to the test.
    alias Zaq.Channels.Api

    def dispatch(%Zaq.Event{} = event) do
      fixture = Process.get(:drive_fixture)
      test = fixture.report_to
      sink = Keyword.get(event.opts, :materialization_sink)
      send(test, {:event, sink, :erlang.external_size(event), self()})
      send(test, {:staging_root, :sys.get_state(sink).dir})

      # An observer may need to attach (trace) before the first chunk is produced.
      if fixture.ack? do
        receive do
          :traced -> :ok
        after
          5_000 -> raise "sink trace observer did not attach"
        end
      end

      response =
        Task.async(fn ->
          Process.put(:drive_fixture, fixture)
          Api.handle_event(event, event.opts[:action], nil)
        end)
        |> Task.await(120_000)

      send(test, {:response, :erlang.external_size(response)})
      response
    end
  end

  setup do
    {:ok, server} =
      Bandit.start_link(plug: DriveServer, port: 0, ip: :loopback, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    config = drive_config()

    Process.put(:drive_fixture, %{
      config: config,
      req_options: [base_url: "http://127.0.0.1:#{port}/drive"],
      report_to: self(),
      ack?: false
    })

    dir = Path.join(System.tmp_dir!(), "streamed_contract_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, config: config, dir: dir}
  end

  # The bridge module is per call; the quota (when given) is the call's own.
  defp context(extra \\ %{}) do
    Map.merge(
      %{
        node_router: Router,
        data_source_bridge_module: DriveBridge,
        actor: %{skip_permissions: true}
      },
      extra
    )
  end

  # The real bridge against the loopback server of this test.
  defp bridge_download(config, %{materialization_sink: sink} = params) when is_pid(sink) do
    %{req_options: req_options} = Process.get(:drive_fixture)

    StreamingDriveClient.with_req_options(req_options, fn ->
      JidoConnectBridge.download_document(config, params)
    end)
  end

  defp drive_record(config, file_id, mime) do
    %Record{
      id: file_id,
      kind: :file,
      name: "#{file_id}.pdf",
      mime_type: mime,
      attributes: %{
        "provider" => "google_drive",
        "config_id" => Integer.to_string(config.id),
        "provider_record_id" => file_id
      }
    }
  end

  defp pread(path, position, length) do
    {:ok, device} = :file.open(String.to_charlist(path), [:read, :raw, :binary])

    try do
      {:ok, data} = :file.pread(device, position, length)
      data
    after
      :file.close(device)
    end
  end

  # Routes the router's event report to an observer that traces the sink's inbound `write`
  # calls (count and largest chunk, data discarded) before the producer sends the first one.
  # The observer reports `{:sink, sink}` and `{:writes, 2}` (a second write was received, so the
  # first has been applied) to the test, and its totals on `report/1`.
  defp observe_sink do
    parent = self()
    fixture = Process.get(:drive_fixture)

    observer =
      spawn_link(fn ->
        receive do
          {:event, sink, _size, from} ->
            tracer = spawn_link(fn -> tally(parent, sink, %{writes: 0, max: 0}) end)
            :erlang.trace(sink, true, [:receive, {:tracer, tracer}])
            send(parent, {:sink, sink, tracer})
            send(from, :traced)
        end

        receive do
          _ -> :ok
        end
      end)

    Process.put(:drive_fixture, %{fixture | report_to: observer, ack?: true})
  end

  defp tally(parent, sink, acc) do
    receive do
      {:trace, ^sink, :receive, {:"$gen_call", _from, {:write, data}}} ->
        acc = %{acc | writes: acc.writes + 1, max: max(acc.max, IO.iodata_length(data))}
        if acc.writes == 2, do: send(parent, {:writes, 2})
        tally(parent, sink, acc)

      {:trace, _, _, _} ->
        tally(parent, sink, acc)

      :report ->
        send(parent, {:write_trace, acc})
    end
  end

  defp report(tracer) do
    send(tracer, :report)
    assert_receive {:write_trace, trace}, 5_000
    trace
  end

  # ---------------------------------------------------------------------------------------
  # 1. Ingestion consumer, files above the legacy 50 MiB cap
  # ---------------------------------------------------------------------------------------
  describe "ingestion consumer streams past the legacy bytes cap" do
    test "a 52 MiB Drive file is staged on disk under an explicit quota, never in an event/record",
         %{config: config} do
      assert Materialization.max_bytes() == 50 * @mib
      assert @big_size > Materialization.max_bytes()

      assert {:ok, %{path: path, cleanup_paths: [staging], record: %Record{}}} =
               RecordSource.materialize(
                 drive_record(config, "big-pdf", "application/pdf"),
                 context(%{materialization_max_bytes: 64 * @mib})
               )

      on_exit(fn -> File.rm_rf(staging) end)

      # The sink pid was the only thing handed to the producer; sample its inbound writes.
      assert_receive {:event, sink, event_size, _from}, 5_000
      assert is_pid(sink)
      assert_receive {:response, response_size}, 5_000

      # Neither the request event nor the producer's response carries the body or Base64.
      assert event_size < 64 * @kib
      assert response_size < 64 * @kib

      assert Path.extname(path) == ".pdf"
      assert File.stat!(path).size == @big_size
      assert pread(path, 0, 8) == <<0, 1, 2, 3, 0, 1, 2, 3>>
      assert pread(path, @big_size - 4, 4) == <<0, 1, 2, 3>>

      # Only the staged file remains in the job root (no `.part`, no second copy).
      assert File.ls!(staging) == [Path.basename(path)]
    end

    test "the same 52 MiB body reaches the sink as many bounded, acknowledged writes",
         %{config: config, dir: dir} do
      {:ok, handle} =
        DataSourceDocument.issue(:google_drive, "big-pdf", %{"config_id" => config.id})

      observe_sink()

      assert {:ok, %{record: %Record{content: nil}, file: file}} =
               Materialization.materialize_file(handle, context(), "Drive", %{},
                 dir: dir,
                 max_bytes: 64 * @mib
               )

      assert_receive {:sink, _sink, tracer}, 5_000
      trace = report(tracer)

      assert file.size == @big_size
      assert File.stat!(file.path).size == @big_size
      assert file.binary?
      # 52 MiB arrived in network-sized pieces, one in flight: never anything near the body.
      assert trace.writes >= 52
      assert trace.max <= @mib
    end

    test "the legacy bytes API keeps its own, smaller cap for the same handle",
         %{config: config} do
      {:ok, handle} =
        DataSourceDocument.issue(:google_drive, "big-pdf", %{"config_id" => config.id})

      assert {:error,
              "Materialization failed: materialization size limit exceeded (1048576 bytes)"} =
               Materialization.materialize(
                 handle,
                 Map.put(context(), :materialization_max_bytes, @mib)
               )
    end

    test "legacy bytes consumers still get decoded JSON rows", %{config: config} do
      {:ok, handle} =
        DataSourceDocument.issue(:google_drive, "json-rows", %{"config_id" => config.id})

      assert {:ok, %{record: %Record{content: [%{"a" => 1}, %{"a" => 2}]}}} =
               Materialization.materialize(handle, context())
    end
  end

  # ---------------------------------------------------------------------------------------
  # 2. JSON arrays in file mode: rows rendered as they arrive
  # ---------------------------------------------------------------------------------------
  describe "file sink renders a JSON array as rows while streaming" do
    test "a body over the old 50 MiB cap is written row by row and keeps the rows' table form",
         %{config: config, dir: dir} do
      assert @rows_json_size > Materialization.max_bytes()
      {:ok, sink} = Sink.open(mode: :file, max_bytes: 64 * @mib, dir: dir)

      result =
        bridge_download(config, %{
          "file_id" => "json-big-rows",
          :materialization_sink => sink
        })

      assert {:ok, %{record: %Record{content: nil, size: @rows}}} = result

      # Many small writes (one per row), none anywhere near the body size.
      assert %{started?: true, size: size, writes: @rows, max_chunk: max_chunk, failure: nil} =
               Sink.stats(sink)

      assert size == @rows_table_size
      assert max_chunk < 2 * @kib

      assert {:ok, %{path: path, size: ^size, text?: true}} = Sink.finish(sink)
      assert pread(path, 0, 16) == "| a |\n| --- |\n| "
      assert pread(path, size - 8, 8) == "\n| end |"
      assert :ok = Sink.release(sink)
    end

    test "a whitespace-padded empty array is an empty text file, not the raw body",
         %{config: config, dir: dir} do
      assert @json_size > Materialization.max_bytes()
      {:ok, sink} = Sink.open(mode: :file, max_bytes: 64 * @mib, dir: dir)

      assert {:ok, %{record: %Record{content: nil}}} =
               bridge_download(config, %{
                 "file_id" => "json-ws",
                 :materialization_sink => sink
               })

      assert %{started?: true, size: 0, failure: nil} = Sink.stats(sink)
      assert {:ok, %{path: path, size: 0, text?: true}} = Sink.finish(sink)
      assert File.read!(path) == ""
      assert :ok = Sink.release(sink)
    end

    test "ingestion stores the rows table as Markdown, like decoded rows",
         %{config: config} do
      assert {:ok, %{path: path, cleanup_paths: [root]}} =
               RecordSource.materialize(
                 drive_record(config, "json-rows", "application/json"),
                 context()
               )

      assert String.ends_with?(path, ".md")
      assert File.read!(path) == "| a |\n| --- |\n| 1 |\n| 2 |"

      File.rm_rf!(root)
      refute File.exists?(root)
    end
  end

  # ---------------------------------------------------------------------------------------
  # 3. Different BEAM nodes
  # ---------------------------------------------------------------------------------------
  describe "producer and consumer on different BEAM nodes" do
    setup %{dir: dir} do
      cookie = :crypto.strong_rand_bytes(12) |> Base.url_encode64() |> String.to_charlist()
      consumer = start_peer("consumer", cookie)
      producer = start_peer("producer", cookie)

      consumer_node = :peer.call(consumer, :erlang, :node, [])
      producer_node = :peer.call(producer, :erlang, :node, [])
      owner = :peer.call(consumer, :erlang, :spawn, [:timer, :sleep, [:infinity]])
      sink_dir = Path.join(dir, "remote")

      {:ok, sink} =
        :peer.call(consumer, Sink, :open, [
          [mode: :file, max_bytes: 4 * @mib, dir: sink_dir, owner: owner]
        ])

      assert node(sink) == consumer_node
      assert consumer_node != producer_node
      refute Node.alive?() and node() in [consumer_node, producer_node]

      {:ok,
       consumer: consumer,
       producer: producer,
       consumer_node: consumer_node,
       producer_node: producer_node,
       owner: owner,
       sink: sink,
       sink_dir: sink_dir}
    end

    test "a sink PID carried in an event accepts writes from a peer node",
         %{consumer: consumer, producer: producer, sink: sink, sink_dir: sink_dir} = ctx do
      event =
        Event.new(
          %{provider: :google_drive, params: %{"file_id" => "x"}},
          :channels,
          opts: [action: :data_source_download_document, materialization_sink: sink]
        )

      # The consumer's directory (a path on the consumer node) is not part of the event.
      refute :erlang.term_to_binary(event) =~ sink_dir

      {producer_ran_on, sink_node, results} =
        eval(
          producer,
          """
          sink = Keyword.fetch!(event.opts, :materialization_sink)
          chunk = :binary.copy(<<7>>, 65_536)
          results = for _ <- 1..48, do: Zaq.Materialization.Sink.write(sink, chunk)
          {node(), node(sink), Enum.uniq(results)}
          """,
          event: event
        )

      assert producer_ran_on == ctx.producer_node
      assert sink_node == ctx.consumer_node
      assert results == [:ok]

      assert %{size: size, writes: 48, max_chunk: @chunk, failure: nil} =
               :peer.call(consumer, Sink, :stats, [sink])

      assert size == 48 * @chunk
      assert {:ok, %{path: path, size: ^size}} = :peer.call(consumer, Sink, :finish, [sink])
      assert Path.dirname(path) == sink_dir
      assert File.stat!(path).size == 48 * @chunk
      assert pread(path, 0, 3) == <<7, 7, 7>>
    end

    test "overflow on the consumer rejects the remote write and removes the partial file",
         %{consumer: consumer, producer: producer, sink: sink, sink_dir: sink_dir} do
      # Quota is 4 MiB; 65 chunks of 64 KiB is one chunk over.
      results =
        eval(
          producer,
          """
          chunk = :binary.copy(<<1>>, 65_536)
          Enum.map(1..65, fn _ -> Zaq.Materialization.Sink.write(sink, chunk) end)
          """,
          sink: sink
        )

      assert Enum.take(results, 64) |> Enum.uniq() == [:ok]
      assert List.last(results) == {:error, {:materialization_limit, 4 * @mib}}
      # The failed sink reports it to later writers and has already deleted its partial file.
      assert {:error, {:materialization_limit, _}} =
               :peer.call(producer, Sink, :write, [sink, "x"])

      assert File.ls!(sink_dir) == []
      assert {:error, {:materialization_limit, _}} = :peer.call(consumer, Sink, :finish, [sink])
    end

    test "a producer node that dies mid-stream leaves cleanup to the consumer's owner",
         %{consumer: consumer, producer: producer, sink: sink, sink_dir: sink_dir} do
      assert eval(producer, "Zaq.Materialization.Sink.write(sink, \"partial\")", sink: sink) ==
               :ok

      assert [part] = File.ls!(sink_dir)
      :ok = :peer.stop(producer)

      # The sink is not tied to the producer: it still accepts writes and is owner-driven.
      assert :ok = :peer.call(consumer, Sink, :write, [sink, "more"])
      assert File.ls!(sink_dir) == [part]
      assert :ok = :peer.call(consumer, Sink, :discard, [sink])
      assert File.ls!(sink_dir) == []
    end

    test "owner death on the consumer node closes the sink and fails the remote producer",
         %{consumer: consumer, producer: producer, owner: owner, sink: sink, sink_dir: sink_dir} do
      assert eval(producer, "Zaq.Materialization.Sink.write(sink, \"partial\")", sink: sink) ==
               :ok

      assert [_part] = File.ls!(sink_dir)

      # Wait on the sink's own exit signal, not on time.
      assert :down =
               eval(
                 consumer,
                 """
                 ref = Process.monitor(sink)
                 Process.exit(owner, :kill)

                 receive do
                   {:DOWN, ^ref, :process, _pid, _reason} -> :down
                 after
                   10_000 -> :timeout
                 end
                 """,
                 sink: sink,
                 owner: owner
               )

      assert File.ls!(sink_dir) == []

      assert {:error, :sink_closed} =
               eval(producer, "Zaq.Materialization.Sink.write(sink, \"late\")", sink: sink)
    end

    test "losing the consumer node ends a running remote producer instead of hanging it",
         %{consumer: consumer, producer: producer, sink: sink} do
      assert eval(producer, "Zaq.Materialization.Sink.write(sink, \"first\")", sink: sink) == :ok

      task =
        Task.async(fn ->
          eval(
            producer,
            """
            chunk = :binary.copy(<<2>>, 4_096)

            Stream.repeatedly(fn -> Zaq.Materialization.Sink.write(sink, chunk) end)
            |> Enum.find(&(&1 != :ok))
            """,
            [sink: sink],
            60_000
          )
        end)

      # The sink's node goes away abruptly (no graceful stop of the sink).
      :peer.stop(consumer)

      assert {:error, reason} = Task.await(task, 60_000)
      # `:sink_closed` (node/connection lost) or the quota the endless writer ran into first.
      assert reason == :sink_closed or match?({:materialization_limit, _}, reason)
    end
  end

  # ---------------------------------------------------------------------------------------
  # 4. Cleanup and ownership
  # ---------------------------------------------------------------------------------------
  describe "cleanup and ownership" do
    test "a source that drops the connection mid-body leaves no partial file",
         %{config: config, dir: dir} do
      {:ok, handle} =
        DataSourceDocument.issue(:google_drive, "aborts", %{"config_id" => config.id})

      assert {:error, "Drive: " <> _} =
               Materialization.materialize_file(handle, context(), "Drive", %{},
                 dir: dir,
                 max_bytes: 64 * @mib
               )

      assert File.ls!(dir) == []
    end

    test "ingestion removes its staging root when the quota is exceeded mid-stream",
         %{config: config} do
      assert {:error, "Data source document download failed: materialization size limit" <> _} =
               RecordSource.materialize(
                 drive_record(config, "big-pdf", "application/pdf"),
                 context(%{materialization_max_bytes: 8 * @mib})
               )

      assert_receive {:staging_root, root}, 5_000
      refute File.exists?(root)
    end

    test "killing the consumer mid-stream removes the partial file and closes the sink",
         %{config: config, dir: dir} do
      {:ok, handle} =
        DataSourceDocument.issue(:google_drive, "endless", %{"config_id" => config.id})

      observe_sink()

      fixture = Process.get(:drive_fixture)

      consumer =
        spawn(fn ->
          Process.put(:drive_fixture, fixture)

          Materialization.materialize_file(handle, context(), "Drive", %{},
            dir: dir,
            max_bytes: 2_000 * @mib
          )
        end)

      assert_receive {:sink, sink, _tracer}, 5_000
      sink_ref = Process.monitor(sink)
      assert_receive {:writes, 2}, 10_000
      assert [_part] = File.ls!(dir)

      Process.exit(consumer, :kill)
      assert_receive {:DOWN, ^sink_ref, :process, ^sink, _reason}, 10_000
      assert File.ls!(dir) == []
    end

    test "a finished file is owned until the caller releases it, then it outlives everything",
         %{dir: dir} do
      parent = self()

      {caller, ref} =
        spawn_monitor(fn ->
          {:ok, sink} = Sink.open(mode: :file, max_bytes: @mib, dir: dir)
          :ok = Sink.write(sink, "kept")
          {:ok, %{path: path}} = Sink.finish(sink)
          :ok = Sink.release(sink)
          send(parent, {:released, sink, path})
        end)

      assert_receive {:released, sink, path}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^caller, _}, 5_000
      refute Process.alive?(sink)
      assert File.read!(path) == "kept"
      File.rm!(path)
    end

    test "a caller that dies after finish but before releasing leaves no completed file",
         %{dir: dir} do
      parent = self()

      {caller, ref} =
        spawn_monitor(fn ->
          {:ok, sink} = Sink.open(mode: :file, max_bytes: @mib, dir: dir)
          :ok = Sink.write(sink, "completed")
          {:ok, %{path: path}} = Sink.finish(sink)
          send(parent, {:finished, sink, path})
        end)

      assert_receive {:finished, sink, path}, 5_000
      sink_ref = Process.monitor(sink)
      assert_receive {:DOWN, ^ref, :process, ^caller, _}, 5_000
      assert_receive {:DOWN, ^sink_ref, :process, ^sink, _}, 5_000
      refute File.exists?(path)
      assert File.ls!(dir) == []
    end

    test "a started file sink whose owner exits before finish removes its part file",
         %{dir: dir} do
      parent = self()

      {owner, ref} =
        spawn_monitor(fn ->
          {:ok, sink} = Sink.open(mode: :file, max_bytes: @mib, dir: dir)
          :ok = Sink.write(sink, "partial")
          send(parent, {:sink, sink})
        end)

      assert_receive {:sink, sink}, 5_000
      sink_ref = Process.monitor(sink)
      assert_receive {:DOWN, ^ref, :process, ^owner, _}, 5_000
      assert_receive {:DOWN, ^sink_ref, :process, ^sink, _}, 5_000
      assert File.ls!(dir) == []
    end
  end

  # ---------------------------------------------------------------------------------------
  # helpers: isolated peer nodes, drive config
  # ---------------------------------------------------------------------------------------

  # Each peer is a separate BEAM with a private cookie, two schedulers and stdio control, so
  # this VM's own node name and cookie are never touched.
  defp start_peer(role, cookie) do
    paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    {:ok, peer, _node} =
      :peer.start_link(%{
        name: String.to_atom("zaq875_#{role}_#{System.unique_integer([:positive])}"),
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: [~c"-setcookie", cookie, ~c"+S", ~c"2:2"] ++ paths
      })

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        _, _ -> :ok
      end
    end)

    {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:elixir])
    peer
  end

  defp eval(peer, code, bindings, timeout \\ 30_000) do
    {value, _bindings} = :peer.call(peer, Code, :eval_string, [code, bindings], timeout)
    value
  end

  defp drive_config do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "drive-#{System.unique_integer([:positive])}",
        provider: "google_drive",
        kind: "data_source",
        enabled: true,
        settings: %{}
      })
      |> Repo.insert!()

    {:ok, credential} =
      Connect.create_credential(%{
        name: "cred-#{System.unique_integer([:positive])}",
        provider: "google_drive",
        auth_kind: "oauth2",
        request_format: "bearer",
        user_level: false,
        metadata: %{},
        client_id: "client",
        client_secret: "secret",
        scopes: ["https://www.googleapis.com/auth/drive.readonly"]
      })

    config =
      config
      |> ChannelConfig.changeset(%{
        "settings" => %{"connect" => %{"credential_id" => Integer.to_string(credential.id)}}
      })
      |> Repo.update!()

    {:ok, _grant} =
      Connect.issue_grant(%{
        credential_id: credential.id,
        auth_kind: "oauth2",
        resource_type: "data_source",
        resource_id: config.id,
        owner_type: "org",
        owner_id: nil,
        request_format: "bearer",
        metadata: %{},
        status: "active",
        access_token: "access-token",
        refresh_token: "refresh-token",
        scopes: ["https://www.googleapis.com/auth/drive.readonly"]
      })

    config
  end
end

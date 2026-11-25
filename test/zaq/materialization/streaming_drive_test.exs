defmodule Zaq.Materialization.StreamingDriveTest do
  @moduledoc """
  Remote acquisition streams into a consumer-owned sink (issue #875). The real
  `jido_connect` catalog and Google Drive action handler run against a loopback HTTP server;
  `StreamingDriveClient` is injected through the dependency's own `google_drive_client` seam.

  No application environment is changed: the loopback base URL is a process-scoped Req option
  (`StreamingDriveClient.with_req_options/2`), the bridge module and quotas travel in the call's
  context, and the Drive fixture is carried by the calling process. A consumer process spawned by
  a test is handed the fixture explicitly.
  """
  use Zaq.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Jido.Connect.Google.Drive.Client.Response
  alias Zaq.Channels.JidoConnectBridge
  alias Zaq.Channels.JidoConnectBridge.StreamingDriveClient
  alias Zaq.Channels.Materializers.DataSourceDocument
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Connect
  alias Zaq.Materialization
  alias Zaq.Materialization.{RowsMarkdown, Sink}
  alias Zaq.Repo

  @mib 1024 * 1024
  @large 61_440 * 1024

  defmodule DriveServer do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(%{path_info: ["drive", "v3", "files", "exact"]} = conn, _opts),
      do: send_resp(conn, 200, String.duplicate("x", 100))

    def call(%{path_info: ["drive", "v3", "files", "declared"]} = conn, _opts),
      do: send_resp(conn, 200, String.duplicate("x", 5_000))

    def call(%{path_info: ["drive", "v3", "files", "empty"]} = conn, _opts),
      do: send_resp(conn, 200, "")

    def call(%{path_info: ["drive", "v3", "files", "endless"]} = conn, hits) do
      conn = send_chunked(conn, 200)
      stream(conn, 0, 100_000, :binary.copy("x", 1024), hits)
    end

    def call(%{path_info: ["drive", "v3", "files", "large"]} = conn, hits) do
      # 60 MiB, over the old 50 MiB cap, with no content-length: generated chunk by chunk.
      conn = send_chunked(put_resp_content_type(conn, "application/pdf"), 200)
      stream(conn, 0, 60 * 16, :binary.copy(<<0>>, 64 * 1024), hits)
    end

    def call(%{path_info: ["drive", "v3", "files", "flaky"]} = conn, hits) do
      if Agent.get_and_update(hits, &{&1, &1 + 1}) == 0,
        do: send_resp(conn, 503, ~s({"error":{"message":"busy"}})),
        else: send_resp(conn, 200, "recovered")
    end

    def call(%{path_info: ["drive", "v3", "files", "forbidden"]} = conn, _opts) do
      body = ~s({"error":{"message":"denied","pad":"#{String.duplicate("x", 3_000)}"}})
      conn |> put_resp_content_type("application/json") |> send_resp(403, body)
    end

    def call(%{path_info: ["drive", "v3", "files", "gzip"]} = conn, _opts),
      do:
        conn |> put_resp_header("content-encoding", "gzip") |> send_resp(200, :zlib.gzip("hello"))

    def call(%{path_info: ["drive", "v3", "files", "csv"]} = conn, _opts),
      do: conn |> put_resp_content_type("text/csv") |> send_resp(200, "a,b\n1,2\n")

    def call(%{path_info: ["drive", "v3", "files", "json-rows"]} = conn, _opts),
      do:
        conn |> put_resp_content_type("application/json") |> send_resp(200, ~s([{"a":1},{"a":2}]))

    # Rows of different shapes, served in 3-byte pieces so every token straddles chunks.
    def call(%{path_info: ["drive", "v3", "files", "json-mixed"]} = conn, _opts) do
      conn = send_chunked(put_resp_content_type(conn, "application/json"), 200)
      body = " \n" <> mixed_json()

      body
      |> :binary.bin_to_list()
      |> Enum.chunk_every(3)
      |> Enum.reduce(conn, fn piece, conn ->
        {:ok, conn} = chunk(conn, :binary.list_to_bin(piece))
        conn
      end)
    end

    # A first chunk of blanks only, then the array: the mode is decided on the first
    # non-blank byte, not on the blanks.
    def call(%{path_info: ["drive", "v3", "files", "json-padded"]} = conn, _opts) do
      conn = send_chunked(put_resp_content_type(conn, "application/json"), 200)
      {:ok, conn} = chunk(conn, String.duplicate(" \t\r\n", 512))
      {:ok, conn} = chunk(conn, ~s([{"a":1}]))
      conn
    end

    def call(%{path_info: ["drive", "v3", "files", "json-blank"]} = conn, _opts),
      do: conn |> put_resp_content_type("application/json") |> send_resp(200, "   \n ")

    def call(%{path_info: ["drive", "v3", "files", "json-empty"]} = conn, _opts),
      do: conn |> put_resp_content_type("application/json") |> send_resp(200, " [ ] ")

    def call(%{path_info: ["drive", "v3", "files", "json-truncated"]} = conn, _opts),
      do: conn |> put_resp_content_type("application/json") |> send_resp(200, ~s([{"a":1},{"a"))

    def call(%{path_info: ["drive", "v3", "files", "json-trailing"]} = conn, _opts),
      do: conn |> put_resp_content_type("application/json") |> send_resp(200, ~s([{"a":1}] x))

    def call(%{path_info: ["drive", "v3", "files", "json-scalar"]} = conn, _opts),
      do: conn |> put_resp_content_type("application/json") |> send_resp(200, ~s("hello"))

    def call(%{path_info: ["drive", "v3", "files", "json-object"]} = conn, hits) do
      Agent.update(hits, &(&1 + 1))
      conn |> put_resp_content_type("application/json") |> send_resp(200, ~s({"a":1}))
    end

    def call(%{path_info: ["drive", "v3", "files", "binary"]} = conn, _opts),
      do: conn |> put_resp_content_type("application/pdf") |> send_resp(200, <<0, 1, 2, 255>>)

    def call(%{path_info: ["drive", "v3", "files", "doc", "export"]} = conn, _opts),
      do:
        conn |> put_resp_content_type("text/plain") |> send_resp(200, String.duplicate("e", 500))

    def call(conn, _opts), do: send_resp(conn, 404, ~s({"error":{"message":"missing"}}))

    def mixed_json do
      ~S([{"b":1,"a":"x|y","n":null},{"a":[1,{"z":null}],"c":true,"b":2.5},{"a":"\u00e9\ud83d\ude00"}])
    end

    defp stream(conn, sent, total, _data, _hits) when sent >= total, do: conn

    defp stream(conn, sent, total, data, hits) do
      case chunk(conn, data) do
        {:ok, conn} ->
          Agent.update(hits, fn _ -> sent + 1 end)
          stream(conn, sent + 1, total, data, hits)

        {:error, _closed} ->
          conn
      end
    end
  end

  defmodule DriveBridge do
    @moduledoc false
    # Stands in for the DataSourceBridge dispatcher: resolves the config, calls the real bridge.
    alias Zaq.Channels.JidoConnectBridge

    # The fixture is per calling process (`Process.put(:drive_fixture, ...)`), not global state.
    def download_document(_provider, %{materialization_sink: sink} = params, _context)
        when is_pid(sink) do
      %{config: config, req_options: req_options} = Process.get(:drive_fixture)

      StreamingDriveClient.with_req_options(req_options, fn ->
        JidoConnectBridge.download_document(config, params)
      end)
    end
  end

  defmodule ParamsBridge do
    @moduledoc false
    # Reports the params the Channels API hands to the bridge, to the calling process.
    def download_document(_provider, params, _context) do
      send(self(), {:bridge_params, params})
      :recorded
    end
  end

  defmodule Router do
    @moduledoc false
    # Runs the real Channels role API in the calling process.
    alias Zaq.Channels.Api

    def dispatch(%Zaq.Event{} = event),
      do: Api.handle_event(event, event.opts[:action], nil)
  end

  setup do
    {:ok, hits} = Agent.start_link(fn -> 0 end)

    {:ok, server} =
      Bandit.start_link(plug: {DriveServer, hits}, port: 0, ip: :loopback, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    config = drive_config()
    fixture = %{config: config, req_options: [base_url: "http://127.0.0.1:#{port}/drive"]}
    Process.put(:drive_fixture, fixture)

    dir = Path.join(System.tmp_dir!(), "streaming_drive_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, config: config, dir: dir, hits: hits}
  end

  defp download(config, file_id, sink_opts, extra \\ %{}) do
    {:ok, sink} = Sink.open(sink_opts)
    params = Map.merge(%{"file_id" => file_id, :materialization_sink => sink}, extra)
    {bridge_download(config, params), sink}
  end

  # The real bridge against the loopback server of this test.
  defp bridge_download(config, %{materialization_sink: sink} = params) when is_pid(sink) do
    %{req_options: req_options} = Process.get(:drive_fixture)

    StreamingDriveClient.with_req_options(req_options, fn ->
      JidoConnectBridge.download_document(config, params)
    end)
  end

  describe "bridge streaming into a sink" do
    test "a body exactly at the quota succeeds and reaches the sink, not the record",
         %{config: config} do
      {result, sink} = download(config, "exact", mode: :memory, max_bytes: 100)

      assert {:ok, %{record: record}} = result
      assert record.size == 100
      assert record.content == nil
      assert {:ok, %{binary: body, text?: true}} = Sink.finish(sink)
      assert byte_size(body) == 100
    end

    test "one byte over the quota is rejected", %{config: config} do
      {result, sink} = download(config, "exact", mode: :memory, max_bytes: 99)

      assert {:error, _} = result
      assert %{failure: {:materialization_limit, 99}} = Sink.stats(sink)
    end

    test "a declared content-length over the quota is rejected before any body byte",
         %{config: config} do
      {result, sink} = download(config, "declared", mode: :memory, max_bytes: 1_000)

      assert {:error, _} = result
      assert %{failure: {:materialization_limit, 1_000}, size: 0, writes: 0} = Sink.stats(sink)
    end

    test "an undeclared endless stream is cut off instead of being read to the end",
         %{config: config, hits: hits} do
      {result, sink} = download(config, "endless", mode: :memory, max_bytes: 10 * 1024)

      assert {:error, _} = result
      assert %{failure: {:materialization_limit, 10_240}} = Sink.stats(sink)
      # The server had 100 MB to send; the client closed the connection long before that.
      assert Agent.get(hits, & &1) < 5_000
    end

    test "a 60 MiB body (over the old 50 MiB cap) flows in small acknowledged chunks",
         %{config: config, dir: dir} do
      {result, sink} = download(config, "large", mode: :file, max_bytes: 64 * @mib, dir: dir)

      assert {:ok, %{record: %{size: @large, content: nil}}} = result
      assert %{size: @large, writes: writes, max_chunk: max_chunk} = Sink.stats(sink)
      # Nothing ever held more than one network-sized chunk; the file is on disk.
      assert max_chunk <= @mib
      assert writes >= 60
      assert {:ok, %{path: path}} = Sink.finish(sink)
      assert File.stat!(path).size == @large
    end

    test "default transient retry is preserved", %{config: config} do
      {result, sink} = download(config, "flaky", mode: :memory, max_bytes: 100)

      assert {:ok, %{record: %{size: 9}}} = result
      assert {:ok, %{binary: "recovered"}} = Sink.finish(sink)
    end

    test "a connection lost after an accepted chunk is not retried", %{config: config} do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)
      on_exit(fn -> :gen_tcp.close(listen) end)
      test = self()
      {:ok, sink} = Sink.open(mode: :memory, max_bytes: 1_000)
      :erlang.trace(sink, true, [:receive])

      server =
        spawn_link(fn ->
          {:ok, socket} = :gen_tcp.accept(listen)
          {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)

          :ok =
            :gen_tcp.send(
              socket,
              "HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\n" <> String.duplicate("p", 50)
            )

          send(test, {:first_response_sent, self()})

          receive do
            :disconnect -> :gen_tcp.close(socket)
          end

          case :gen_tcp.accept(listen) do
            {:ok, retry} ->
              send(test, :second_attempt)
              :gen_tcp.close(retry)

            {:error, :closed} ->
              :ok
          end

          send(test, :server_done)
        end)

      task =
        Task.async(fn ->
          receive do
            :start ->
              StreamingDriveClient.with_req_options(
                [base_url: "http://127.0.0.1:#{port}/drive"],
                fn ->
                  JidoConnectBridge.download_document(config, %{
                    "file_id" => "partial",
                    materialization_sink: sink
                  })
                end
              )
          end
        end)

      Sandbox.allow(Zaq.Repo, self(), task.pid)
      send(task.pid, :start)
      assert_receive {:first_response_sent, ^server}, 5_000
      assert_receive {:trace, ^sink, :receive, {:"$gen_call", _, {:write, data}}}, 5_000
      assert IO.iodata_length(data) > 0
      assert %{size: accepted} = Sink.stats(sink)
      assert accepted > 0
      send(server, :disconnect)
      assert {:error, _} = Task.await(task, 30_000)
      assert %{size: size} = Sink.stats(sink)
      assert size > 0 and size <= 50
      :gen_tcp.close(listen)
      assert_receive :server_done, 5_000
      refute_received :second_attempt
    end

    test "a provider error keeps its shape even when its body exceeds a tiny quota",
         %{config: config} do
      {result, sink} = download(config, "forbidden", mode: :memory, max_bytes: 10)

      assert {:error, %{code: :provider_forbidden, status: 403, display_message: "denied"}} =
               result

      assert %{started?: false, size: 0, failure: nil} = Sink.stats(sink)
    end

    test "content-encoding other than identity is rejected, not stored", %{config: config} do
      {result, sink} = download(config, "gzip", mode: :memory, max_bytes: 1_000)

      assert {:error, %{code: :provider_error, message: "Provider handler failed"}} = result
      assert %{size: 0} = Sink.stats(sink)
    end

    test "an empty 200 is a materialized empty body", %{config: config} do
      {result, sink} = download(config, "empty", mode: :memory, max_bytes: 10)

      assert {:ok, %{record: %{size: 0}}} = result
      assert %{started?: true, size: 0} = Sink.stats(sink)
    end

    test "CSV is streamed as text; binary is classified as binary", %{config: config} do
      {csv, csv_sink} = download(config, "csv", mode: :memory, max_bytes: 100)
      assert {:ok, %{record: %{content: nil}}} = csv
      assert {:ok, %{binary: "a,b\n1,2\n", text?: true}} = Sink.finish(csv_sink)

      {bin, bin_sink} = download(config, "binary", mode: :memory, max_bytes: 100)
      assert {:ok, %{record: %{content: nil}}} = bin
      assert {:ok, %{binary: <<0, 1, 2, 255>>, text?: false}} = Sink.finish(bin_sink)
    end

    test "JSON keeps the dependency's decoded behaviour, bounded by the in-memory cap",
         %{config: config, hits: hits} do
      {rows, sink} = download(config, "json-rows", mode: :memory, max_bytes: 1_000)
      assert {:ok, %{record: %{content: [%{"a" => 1}, %{"a" => 2}]}}} = rows
      assert %{started?: false} = Sink.stats(sink)

      # The unmodified dependency rejects a decoded JSON object; so does the streaming path.
      {object, _} = download(config, "json-object", mode: :memory, max_bytes: 1_000)

      assert {:error,
              %{code: :provider_error, message: "Google Drive file content response was invalid"}} =
               object

      assert Agent.get(hits, & &1) == 1

      # Compare at the dependency's buffered response-normalization boundary. The real
      # no-sink bridge selects its default client, whose endpoint cannot be scoped per call.
      response = {:ok, %{status: 200, body: %{"a" => 1}, headers: %{}}}

      assert {:error, %{reason: :invalid_response}} =
               Response.handle_file_content_response(
                 response,
                 %{file_id: "json-object"}
               )
    end

    test "a per-call quota applies to decoded JSON in the bytes API, not only the global cap",
         %{config: config} do
      # json-rows is 17 bytes: far under the 50 MiB global cap, over this call's quota.
      {over, sink} = download(config, "json-rows", mode: :memory, max_bytes: 10)
      assert {:error, _} = over
      assert %{failure: {:materialization_limit, 10}} = Sink.stats(sink)

      {exact, _} = download(config, "json-rows", mode: :memory, max_bytes: 17)
      assert {:ok, %{record: %{content: [%{"a" => 1}, %{"a" => 2}]}}} = exact
    end

    test "export requests stream the same way", %{config: config} do
      {result, sink} =
        download(config, "doc", [mode: :memory, max_bytes: 500], %{
          "export_mime_type" => "text/plain",
          "document_mime_type" => "application/vnd.google-apps.document"
        })

      assert {:ok, %{record: %{size: 500}}} = result
      assert {:ok, %{binary: body}} = Sink.finish(sink)
      assert byte_size(body) == 500
    end

    test "the streaming client fails closed outside a sink scope" do
      assert {:error, :materialization_sink_required} =
               StreamingDriveClient.download_file(%{file_id: "exact"}, "token")
    end
  end

  describe "JSON arrays in file mode" do
    defp file_download(config, dir, file_id, max_bytes \\ 1_000) do
      download(config, file_id, mode: :file, max_bytes: max_bytes, dir: dir)
    end

    defp finished_text(sink) do
      assert {:ok, %{path: path, text?: true}} = Sink.finish(sink)
      text = File.read!(path)
      assert :ok = Sink.release(sink)
      text
    end

    test "an array becomes the table ingestion builds from decoded rows",
         %{config: config, dir: dir} do
      {result, sink} = file_download(config, dir, "json-rows")

      assert {:ok, %{record: %{content: nil, size: 2}}} = result
      assert finished_text(sink) == "| a |\n| --- |\n| 1 |\n| 2 |"
    end

    test "rows of different shapes match the decoded-rows conversion across tiny chunks",
         %{config: config, dir: dir} do
      {memory, _} = download(config, "json-mixed", mode: :memory, max_bytes: 1_000)
      assert {:ok, %{record: %{content: rows}}} = memory
      expected = RowsMarkdown.render(rows)

      {result, sink} = file_download(config, dir, "json-mixed")
      assert {:ok, %{record: %{content: nil, size: 3}}} = result
      text = finished_text(sink)

      assert text == expected

      assert text ==
               Enum.join(
                 [
                   "| a | b | n |",
                   "| --- | --- | --- |",
                   "| x|y | 1 |  |",
                   ~s(| [1,{"z":null}] | 2.5 |  |),
                   "| \u00e9\u{1F600} |  |  |"
                 ],
                 "\n"
               )
    end

    test "a blank-only first chunk does not decide the mode: the array still streams as rows",
         %{config: config, dir: dir} do
      {result, sink} = file_download(config, dir, "json-padded", 4_000)

      assert {:ok, %{record: %{content: nil}}} = result
      assert %{size: 19, started?: true} = Sink.stats(sink)
      assert finished_text(sink) == "| a |\n| --- |\n| 1 |"
    end

    test "whitespace before the first JSON value counts against the raw quota", %{
      config: config,
      dir: dir
    } do
      {result, sink} = file_download(config, dir, "json-padded", 1_000)
      assert {:error, _} = result
      assert %{failure: {:materialization_limit, 1_000}} = Sink.stats(sink)
      assert File.ls!(dir) == []
    end

    test "a body of only blanks is invalid content, not an empty file",
         %{config: config, dir: dir} do
      {result, sink} = file_download(config, dir, "json-blank")

      assert {:error, _} = result
      assert %{size: 0} = Sink.stats(sink)
    end

    test "an empty array is a materialized empty text file", %{config: config, dir: dir} do
      {result, sink} = file_download(config, dir, "json-empty")

      assert {:ok, %{record: %{content: nil}}} = result
      assert %{started?: true} = Sink.stats(sink)
      assert finished_text(sink) == ""
    end

    test "malformed or trailing JSON is an error and leaves no file",
         %{config: config, dir: dir} do
      for id <- ["json-truncated", "json-trailing"] do
        {result, sink} = file_download(config, dir, id)

        assert {:error,
                %{
                  code: :provider_error,
                  message: "Google Drive file content response was invalid"
                }} = result

        assert {:error, :invalid_json} = Sink.finish(sink)
      end

      assert File.ls!(dir) == []
    end

    test "other JSON values keep the dependency's decoded behaviour", %{config: config, dir: dir} do
      {object, _} = file_download(config, dir, "json-object")
      assert {:error, _} = object

      {scalar, sink} = file_download(config, dir, "json-scalar")
      assert {:ok, %{record: %{content: "hello"}}} = scalar
      assert %{started?: false} = Sink.stats(sink)
    end

    test "rendered rows are held to the quota even when the raw JSON fits", %{
      config: config,
      dir: dir
    } do
      # Raw JSON is 17 bytes; its Markdown table is 25 bytes.
      {result, sink} = file_download(config, dir, "json-rows", 18)

      assert {:error, _} = result
      assert %{failure: {:materialization_limit, 18}} = Sink.stats(sink)
      assert File.ls!(dir) == []
    end

    test "the raw body is held to the quota", %{config: config, dir: dir} do
      {result, sink} = file_download(config, dir, "json-rows", 10)

      assert {:error, _} = result
      assert %{failure: {:materialization_limit, 10}} = Sink.stats(sink)
      assert File.ls!(dir) == []
    end
  end

  describe "through the consumer path" do
    setup %{config: config} do
      context = %{node_router: Router, data_source_bridge_module: DriveBridge}

      {:ok, handle} =
        DataSourceDocument.issue(:google_drive, "large", %{"config_id" => config.id})

      {:ok, exact} = DataSourceDocument.issue(:google_drive, "exact", %{"config_id" => config.id})
      {:ok, context: context, large: handle, exact: exact}
    end

    test "materialize_file streams a >50 MiB Drive body to disk under an explicit quota",
         %{context: context, large: handle, dir: dir} do
      assert {:ok, %{record: %{content: nil}, file: file}} =
               Materialization.materialize_file(handle, context, "Drive", %{},
                 dir: dir,
                 max_bytes: 64 * @mib
               )

      assert file.size == @large
      assert file.binary?
      assert File.stat!(file.path).size == file.size
    end

    test "quota overflow leaves no partial file", %{context: context, large: handle, dir: dir} do
      assert {:error, message} =
               Materialization.materialize_file(handle, context, "Drive", %{},
                 dir: dir,
                 max_bytes: 10 * @mib
               )

      assert message == "Drive: materialization size limit exceeded (#{10 * @mib} bytes)"
      assert File.ls!(dir) == []
    end

    test "a source error leaves no partial file", %{config: config, context: context, dir: dir} do
      {:ok, handle} =
        DataSourceDocument.issue(:google_drive, "forbidden", %{"config_id" => config.id})

      assert {:error, "Drive: " <> _} =
               Materialization.materialize_file(handle, context, "Drive", %{}, dir: dir)

      assert File.ls!(dir) == []
    end

    test "with an owned directory a quota overflow removes the whole directory",
         %{context: context, large: handle, dir: dir} do
      owned = Path.join(dir, "owned")

      assert {:error, "Drive: materialization size limit exceeded" <> _} =
               Materialization.materialize_file(handle, context, "Drive", %{},
                 dir: owned,
                 own_dir: true,
                 max_bytes: 10 * @mib
               )

      refute File.exists?(owned)
    end

    test "with an owned directory a source error removes the whole directory",
         %{config: config, context: context, dir: dir} do
      owned = Path.join(dir, "owned")

      {:ok, handle} =
        DataSourceDocument.issue(:google_drive, "forbidden", %{"config_id" => config.id})

      assert {:error, "Drive: " <> _} =
               Materialization.materialize_file(handle, context, "Drive", %{},
                 dir: owned,
                 own_dir: true
               )

      refute File.exists?(owned)
    end

    test "a returned file is still owned: its consumer dying before completing removes it",
         %{context: context, exact: exact, dir: dir} do
      owned = Path.join(dir, "owned")
      parent = self()

      fixture = Process.get(:drive_fixture)

      {consumer, ref} =
        spawn_monitor(fn ->
          Process.put(:drive_fixture, fixture)

          {:ok, %{file: file}} =
            Materialization.materialize_file(exact, context, "Drive", %{},
              dir: owned,
              own_dir: true
            )

          # Handed a finished file, but has not completed the hand-over.
          send(parent, {:file, file, self()})

          receive do
            :die -> :ok
          end
        end)

      assert_receive {:file, %{sink: sink, path: path, size: 100}, ^consumer}, 5_000
      sink_ref = Process.monitor(sink)
      assert File.exists?(path)
      assert Process.alive?(sink)

      send(consumer, :die)
      assert_receive {:DOWN, ^ref, :process, ^consumer, _}, 5_000
      assert_receive {:DOWN, ^sink_ref, :process, ^sink, _}, 5_000
      refute File.exists?(path)
      refute File.exists?(owned)
    end

    test "completing the hand-over keeps the (renamed) file after the consumer is gone",
         %{context: context, exact: exact, dir: dir} do
      owned = Path.join(dir, "owned")
      final = Path.join(owned, "final.md")
      parent = self()

      fixture = Process.get(:drive_fixture)

      {consumer, ref} =
        spawn_monitor(fn ->
          Process.put(:drive_fixture, fixture)

          {:ok, %{file: file}} =
            Materialization.materialize_file(exact, context, "Drive", %{},
              dir: owned,
              own_dir: true
            )

          :ok = File.rename(file.path, final)
          :ok = Materialization.complete_file(file)
          send(parent, {:completed, file.sink})
        end)

      assert_receive {:completed, sink}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^consumer, _}, 5_000
      refute Process.alive?(sink)
      assert File.read!(final) == String.duplicate("x", 100)
    end

    test "a discarded file cannot be completed", %{context: context, exact: exact, dir: dir} do
      assert {:ok, %{file: file}} =
               Materialization.materialize_file(exact, context, "Drive", %{}, dir: dir)

      assert :ok = Materialization.discard_file(file)
      refute File.exists?(file.path)
      assert {:error, :file_removed} = Materialization.complete_file(file)
      assert :ok = Materialization.discard_file(file)
    end

    test "the legacy bytes API streams into a capped memory sink",
         %{context: context, exact: exact} do
      assert {:ok, %{record: %{content: content}}} =
               Materialization.materialize(
                 exact,
                 Map.put(context, :materialization_max_bytes, 100)
               )

      assert byte_size(content) == 100

      assert {:error, "Materialization failed: materialization size limit exceeded (99 bytes)"} =
               Materialization.materialize(
                 exact,
                 Map.put(context, :materialization_max_bytes, 99)
               )
    end

    test "a request cannot supply its own sink" do
      {:ok, rogue} = Sink.open(mode: :memory, max_bytes: 1_000)

      event =
        Zaq.Event.new(
          %{
            provider: :google_drive,
            params: %{
              "file_id" => "exact",
              "materialization_sink" => rogue,
              materialization_sink: rogue
            }
          },
          :channels,
          opts: [action: :data_source_download_document, data_source_bridge_module: ParamsBridge]
        )

      assert %{response: :recorded} = Router.dispatch(event)

      # No sink in trusted opts => neither spelling of the request-supplied pid reaches the bridge.
      assert_received {:bridge_params, params}
      refute Map.has_key?(params, :materialization_sink)
      refute Map.has_key?(params, "materialization_sink")
      assert params["file_id"] == "exact"
      assert %{started?: false} = Sink.stats(rogue)

      # A pid in the trusted event options is what the bridge is given.
      {:ok, owned} = Sink.open(mode: :memory, max_bytes: 1_000)
      trusted = %{event | opts: Keyword.put(event.opts, :materialization_sink, owned)}
      assert %{response: :recorded} = Router.dispatch(trusted)
      assert_received {:bridge_params, %{materialization_sink: ^owned}}
    end
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

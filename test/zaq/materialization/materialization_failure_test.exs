defmodule Zaq.Materialization.MaterializationFailureTest do
  use Zaq.DataCase, async: true

  alias Zaq.Channels.Materializers.DataSourceDocument
  alias Zaq.Contracts.Record
  alias Zaq.Event
  alias Zaq.Materialization
  alias Zaq.Materialization.Sink

  defmodule Router do
    def dispatch(%Event{} = event) do
      sink = Keyword.fetch!(event.opts, :materialization_sink)

      case Process.get(:materialization_scenario) do
        :base64 ->
          %{event | response: {:ok, %{content: Process.get(:base64_content), encoding: "base64"}}}

        :inline ->
          %{event | response: {:ok, %{content: "12345"}}}

        :empty ->
          %{event | response: {:ok, %{record: %Record{id: "empty", kind: :file}}}}

        :failed ->
          :ok = Sink.start(sink)
          :ok = Sink.fail(sink, :producer_failed)
          %{event | response: {:ok, %{record: %Record{id: "failed", kind: :file}}}}

        :raise ->
          :ok = Sink.write(sink, "partial")
          send(self(), {:partial_sink, sink})
          raise "producer failed"
      end
    end
  end

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "materialization_failure_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, handle} = DataSourceDocument.issue(:google_drive, "document")
    %{dir: dir, handle: handle, context: %{node_router: Router}}
  end

  test "inline fallback is limited in both APIs", %{handle: handle, context: context, dir: dir} do
    Process.put(:materialization_scenario, :inline)

    assert {:error, "Failed: materialization size limit exceeded (4 bytes)"} =
             Materialization.materialize(
               handle,
               Map.put(context, :materialization_max_bytes, 4),
               "Failed"
             )

    assert {:error, "Failed: materialization size limit exceeded (4 bytes)"} =
             Materialization.materialize_file(handle, context, "Failed", %{},
               dir: dir,
               max_bytes: 4
             )

    assert File.ls!(dir) == []
  end

  test "inline base64 counts decoded bytes at the exact limit", %{
    handle: handle,
    context: context,
    dir: dir
  } do
    Process.put(:materialization_scenario, :base64)

    for {encoded, size} <- [{"YQ==", 1}, {"YWI=", 2}, {"YWJj", 3}] do
      Process.put(:base64_content, encoded)

      assert {:ok, %{record: %{content: ^encoded}}} =
               Materialization.materialize(
                 handle,
                 Map.put(context, :materialization_max_bytes, size),
                 "Failed"
               )

      assert {:ok, %{record: %{content: ^encoded}, file: nil}} =
               Materialization.materialize_file(handle, context, "Failed", %{},
                 dir: dir,
                 max_bytes: size
               )

      if size > 1 do
        assert {:error, "Failed: materialization size limit exceeded" <> _} =
                 Materialization.materialize_file(handle, context, "Failed", %{},
                   dir: dir,
                   max_bytes: size - 1
                 )
      end
    end
  end

  test "no streamed or inline content stays empty and needs no handoff", %{
    handle: handle,
    context: context,
    dir: dir
  } do
    Process.put(:materialization_scenario, :empty)
    assert {:ok, %{record: %{content: nil}}} = Materialization.materialize(handle, context)

    assert {:ok, %{file: nil}} =
             Materialization.materialize_file(handle, context, "Failed", %{}, dir: dir)

    assert :ok = Materialization.complete_file(nil)
    assert :ok = Materialization.discard_file(nil)
  end

  test "producer failure after starting the sink reaches both consumers", %{
    handle: handle,
    context: context,
    dir: dir
  } do
    Process.put(:materialization_scenario, :failed)

    assert {:error, "Failed: :producer_failed"} =
             Materialization.materialize(handle, context, "Failed")

    assert {:error, "Failed: :producer_failed"} =
             Materialization.materialize_file(handle, context, "Failed", %{}, dir: dir)

    assert File.ls!(dir) == []
  end

  test "producer exception removes its partial file and propagates", %{
    handle: handle,
    context: context,
    dir: dir
  } do
    Process.put(:materialization_scenario, :raise)

    assert_raise RuntimeError, "producer failed", fn ->
      Materialization.materialize_file(handle, context, "Failed", %{}, dir: dir)
    end

    assert_received {:partial_sink, sink}
    assert {:error, :sink_closed} = Sink.write(sink, "late")
    assert File.ls!(dir) == []
  end
end

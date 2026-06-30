defmodule Zaq.Engine.Workflows.Steps.BatchSequentialTimingTest do
  @moduledoc """
  Pins down that `Batch` honors `batch_size` over a 3-item collection. With
  delivery `"list"`, a Batch fans out over chunks of `batch_size` items, so it runs
  `ceil(item_count / batch_size)` iterations:

      batch_size: 1 → 3 iterations  ([1] [2] [3])
      batch_size: 2 → 2 iterations  ([1,2] [3])
      batch_size: 3 → 1 iteration   ([1,2,3])

  The body step (`RecordItemTime`) runs once per chunk, logs the execution time,
  and records one `TimeRecorder` mark keyed by the chunk's item indices. The wait
  between work is the production `Zaq.Agent.Tools.Workflow.Sleep` node in the
  Batch's `post_process`. `TimeRecorder.chunks/0` then yields the chunks that ran,
  so we can assert the iteration count and that the chunks partition the items.

  Note: chunk *order* is hash-based, not item-index order, so we assert on the
  set/sizes of chunks, never on which chunk runs first.
  """
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Test.TimeRecorder
  alias Zaq.Engine.Workflows.WorkflowRunAgent

  @emit_module "Zaq.Engine.Workflows.Test.EmitIndexedItems"
  @batch_module "Zaq.Agent.Tools.Workflow.Batch"
  @record_module "Zaq.Engine.Workflows.Test.RecordItemTime"
  @sleep_module "Zaq.Agent.Tools.Workflow.Sleep"

  @item_count 3
  @sleep_ms 2_000

  @source_event %{
    "request" => nil,
    "assigns" => %{"trigger_type" => "manual"},
    "trace_id" => Ecto.UUID.generate()
  }

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    start_supervised!(TimeRecorder)
    :ok
  end

  # emit 3 items → batch(batch_size, process: [record], post_process: [Sleep @sleep_ms])
  defp run_batch(batch_size) do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "Batch Timing bs#{batch_size} #{System.unique_integer()}",
        status: "active",
        nodes: [
          %{name: "emit", type: "action", module: @emit_module, params: %{}, index: 0},
          %{
            name: "batch",
            type: "action",
            module: @batch_module,
            params: %{
              "batch_size" => batch_size,
              "strategy" => "skip_and_continue",
              "process" => [
                %{
                  "name" => "record",
                  "type" => "action",
                  "module" => @record_module,
                  "params" => %{}
                }
              ],
              "post_process" => [
                %{
                  "name" => "sleep",
                  "type" => "action",
                  "module" => @sleep_module,
                  "params" => %{"duration_ms" => @sleep_ms}
                }
              ]
            },
            index: 1
          }
        ],
        edges: [%{from: "emit", to: "batch", mapping: %{"items" => "items"}}]
      })

    {:ok, run} = Workflows.create_run(wf, @source_event)
    {:ok, finished} = WorkflowRunAgent.execute(run)
    assert finished.status == "completed"

    # Marks in execution order: [{chunk_indices, monotonic_ms}, ...]
    TimeRecorder.marks()
  end

  defp chunk_set(marks), do: marks |> Enum.map(&elem(&1, 0)) |> Enum.sort()

  test "batch_size: 1 → 3 iterations of one item each" do
    assert run_batch(1) |> chunk_set() == [[1], [2], [3]]
  end

  test "batch_size: 2 → 2 iterations ([1,2] then [3])" do
    chunks = run_batch(2) |> chunk_set()

    assert length(chunks) == 2
    assert Enum.map(chunks, &length/1) |> Enum.sort() == [1, 2]
    # Chunks partition all 3 items exactly once.
    assert chunks |> List.flatten() |> Enum.sort() == [1, 2, 3]
  end

  test "batch_size: 3 → 1 iteration over all items" do
    assert run_batch(3) |> chunk_set() == [[1, 2, 3]]
  end

  test "iteration count is ceil(item_count / batch_size) for every batch_size" do
    for batch_size <- 1..@item_count do
      TimeRecorder.reset()
      chunks = run_batch(batch_size) |> chunk_set()
      expected = ceil(@item_count / batch_size)

      assert length(chunks) == expected,
             "batch_size #{batch_size}: expected #{expected} iterations, got #{length(chunks)}"
    end
  end

  # SPEC FOR A KNOWN BUG — currently FAILS.
  #
  # Expected per-iteration semantics: with batch_size 1 and a 2s `post_process`
  # sleep, iteration N's body must run only AFTER iteration N-1's post_process
  # (the sleep) finishes. So the three body executions should be spaced ~@sleep_ms
  # apart.
  #
  # Actual: the Batch/map engine runs every chunk's body up front and only then
  # runs the post_process sleeps, so the bodies fire within a few ms of each other
  # — the post_process does NOT gate the next iteration. This assertion documents
  # that gap; fix Batch's per-iteration sequencing to make it pass.
  test "each iteration waits for its post_process before the next iteration runs (batch_size: 1)" do
    times = run_batch(1) |> Enum.map(&elem(&1, 1))

    gaps =
      times
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> b - a end)

    for gap <- gaps do
      assert gap >= @sleep_ms - 50,
             "post_process not respected per iteration: consecutive body steps ran " <>
               "#{gap}ms apart, expected >= #{@sleep_ms}ms (each iteration should wait " <>
               "for its post_process sleep before the next iteration's body runs)"
    end
  end
end

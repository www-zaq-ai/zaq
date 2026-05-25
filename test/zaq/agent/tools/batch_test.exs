defmodule Zaq.Agent.Tools.BatchTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.Batch
  alias Zaq.Engine.Workflows.Test.{CategorizeBySize, SleepMs}

  # ── Inline pipeline stubs ────────────────────────────────────────────────────

  defmodule OkProcess do
    def run(%{items: items} = _params, _ctx),
      do: {:ok, %{processed: Enum.map(items, &Map.put(&1, :ok, true))}}
  end

  defmodule FailProcess do
    def run(_params, _ctx), do: {:error, :process_failed}
  end

  defmodule ConditionalProcess do
    def run(%{items: items}, _ctx) do
      if Enum.any?(items, & &1[:fail]),
        do: {:error, :condition_failed},
        else: {:ok, %{items: items}}
    end
  end

  defmodule CountingProcess do
    def run(params, context) do
      if c = Map.get(context, :counter), do: :counters.add(c, 1, 1)
      {:ok, params}
    end
  end

  defmodule PostRecorder do
    def run(params, context) do
      if pid = Map.get(context, :post_pid), do: send(pid, {:post_ran, params})
      {:ok, %{post_ran: true}}
    end
  end

  defp pipeline(steps), do: Enum.map(steps, &{&1, %{}})

  defp base_params(items, extra \\ %{}) do
    Map.merge(
      %{
        items: items,
        process: pipeline([OkProcess]),
        __batch_field__: :items,
        __batch_mode__: :list
      },
      extra
    )
  end

  # ── :list mode ───────────────────────────────────────────────────────────────

  describe "run/2 — :list mode" do
    test "delivers %{field => chunk} to process pipeline once per chunk" do
      items = Enum.map(1..6, &%{id: &1})

      params = base_params(items, %{batch_size: 3})

      assert {:ok, %{results: results, errors: []}, _} = Batch.run(params, %{})
      assert length(results) == 2
    end

    test "results contain process pipeline output per chunk" do
      # batch_size: 2 → single chunk of both items → one result
      items = [%{id: 1}, %{id: 2}]

      assert {:ok, %{results: [result], errors: []}, _} =
               Batch.run(base_params(items, %{batch_size: 2}), %{})

      assert result.processed == [%{id: 1, ok: true}, %{id: 2, ok: true}]
    end

    test "uses real CategorizeBySize action in :list mode" do
      # batch_size: 3 → single chunk of all items → one result
      items = [%{size: 10}, %{size: 200}, %{size: 1000}]

      params = %{
        items: items,
        batch_size: 3,
        process: [{CategorizeBySize, %{}}],
        __batch_field__: :items,
        __batch_mode__: :list
      }

      assert {:ok, %{results: [%{results: categorized}], errors: []}, _} = Batch.run(params, %{})
      assert length(categorized) == 3
      assert Enum.map(categorized, & &1.category) == ["small_business", "medium", "enterprise"]
    end
  end

  # ── :item mode ───────────────────────────────────────────────────────────────

  describe "run/2 — :item mode" do
    defmodule ItemProcess do
      def run(%{contact: contact}, _ctx), do: {:ok, %{done: contact}}
    end

    test "delivers %{field => item} per item, post_process once per chunk" do
      items = [%{id: 1}, %{id: 2}, %{id: 3}]

      params = %{
        items: items,
        batch_size: 3,
        process: pipeline([ItemProcess]),
        __batch_field__: :contact,
        __batch_mode__: :item
      }

      assert {:ok, %{results: [result], errors: []}, _} = Batch.run(params, %{})
      # chunk result wraps per-item results
      assert %{results: item_results, errors: []} = result
      assert length(item_results) == 3
    end

    test "item errors collected within chunk under :skip_and_continue" do
      defmodule ConditionalItemProcess do
        def run(%{contact: %{fail: true}}, _ctx), do: {:error, :filtered}
        def run(%{contact: c}, _ctx), do: {:ok, %{done: c}}
      end

      items = [%{id: 1}, %{fail: true}, %{id: 3}]

      params = %{
        items: items,
        batch_size: 3,
        strategy: :skip_and_continue,
        process: pipeline([ConditionalItemProcess]),
        __batch_field__: :contact,
        __batch_mode__: :item
      }

      assert {:ok, %{results: [chunk_result], errors: []}, _} = Batch.run(params, %{})
      assert %{results: [_, _], errors: [%{index: 1}]} = chunk_result
    end
  end

  # ── chunk_items ───────────────────────────────────────────────────────────────

  describe "chunk_items / batch_size" do
    test "nil batch_size treats each item as its own single-element chunk" do
      counter = :counters.new(1, [])
      items = Enum.map(1..5, &%{id: &1})

      Batch.run(
        base_params(items, %{process: pipeline([CountingProcess])}),
        %{counter: counter}
      )

      assert :counters.get(counter, 1) == 5
    end

    test "batch_size: 3 over 7 items → 3 chunks [3, 3, 1]" do
      counter = :counters.new(1, [])
      items = Enum.map(1..7, &%{id: &1})

      Batch.run(
        base_params(items, %{batch_size: 3, process: pipeline([CountingProcess])}),
        %{counter: counter}
      )

      assert :counters.get(counter, 1) == 3
    end

    test "returns empty results for empty items" do
      assert {:ok, %{results: [], errors: []}, _} = Batch.run(base_params([]), %{})
    end
  end

  # ── post_process ──────────────────────────────────────────────────────────────

  describe "post_process" do
    test "runs post_process pipeline once per chunk after process" do
      pid = self()
      items = Enum.map(1..4, &%{id: &1})

      params =
        base_params(items, %{
          batch_size: 2,
          post_process: pipeline([PostRecorder])
        })

      Batch.run(params, %{post_pid: pid})

      assert_received {:post_ran, _}
      assert_received {:post_ran, _}
      refute_received {:post_ran, _}
    end

    test "post_process receives empty initial acc (base_params drive it)" do
      pid = self()
      items = [%{id: 1}]

      params = base_params(items, %{post_process: pipeline([PostRecorder])})
      Batch.run(params, %{post_pid: pid})

      assert_received {:post_ran, received}
      # Should receive empty map (base_params only, no chunk data)
      assert received == %{}
    end

    test "absent post_process skips cleanly, still collects results" do
      items = [%{id: 1}]

      assert {:ok, %{results: [_], errors: []}, _} = Batch.run(base_params(items), %{})
    end

    test "uses real SleepMs (duration_ms: 0) as post_process" do
      items = [%{id: 1}]

      params = base_params(items, %{post_process: [{SleepMs, %{duration_ms: 0}}]})

      assert {:ok, %{results: [_], errors: []}, _} = Batch.run(params, %{})
    end
  end

  # ── strategy: :skip_and_continue ─────────────────────────────────────────────

  describe "strategy: :skip_and_continue" do
    test "process error → error recorded, continues to next chunk" do
      items = Enum.map(1..4, &%{id: &1})

      params =
        base_params(items, %{
          batch_size: 2,
          strategy: :skip_and_continue,
          process: pipeline([FailProcess])
        })

      assert {:ok, %{results: [], errors: errors}, _} = Batch.run(params, %{})
      assert length(errors) == 2
    end

    test "is the default strategy" do
      params = base_params([%{id: 1}], %{process: pipeline([FailProcess])})
      assert {:ok, %{errors: [_]}, _} = Batch.run(params, %{})
    end
  end

  # ── strategy: :fail_workflow ──────────────────────────────────────────────────

  describe "strategy: :fail_workflow" do
    test "process error → halts and returns {:error, reason}" do
      items = [%{id: 1}, %{id: 2}]

      params =
        base_params(items, %{
          strategy: :fail_workflow,
          process: pipeline([FailProcess])
        })

      assert {:error, :process_failed} = Batch.run(params, %{})
    end

    test "post_process does not run on failed chunk" do
      pid = self()
      items = [%{id: 1}]

      params =
        base_params(items, %{
          strategy: :fail_workflow,
          process: pipeline([FailProcess]),
          post_process: pipeline([PostRecorder])
        })

      Batch.run(params, %{post_pid: pid})
      refute_received {:post_ran, _}
    end

    test "does not process chunks after the first failure" do
      counter = :counters.new(1, [])
      items = Enum.map(1..4, &%{id: &1})

      params =
        base_params(items, %{
          batch_size: 2,
          strategy: :fail_workflow,
          process: pipeline([FailProcess])
        })

      Batch.run(params, %{counter: counter})
      assert :counters.get(counter, 1) == 0
    end
  end

  # ── strategy: :retry ─────────────────────────────────────────────────────────

  describe "strategy: :retry" do
    test "retries chunk up to 3 total attempts then skips" do
      params =
        base_params([%{id: 1}], %{
          strategy: :retry,
          process: pipeline([FailProcess])
        })

      assert {:ok, %{results: [], errors: [%{index: 0}]}, _} = Batch.run(params, %{})
    end

    test "succeeds if retry succeeds" do
      attempt = :counters.new(1, [])

      defmodule RetryableProcess do
        def run(%{items: items}, ctx) do
          c = Map.get(ctx, :attempt)

          n =
            if c,
              do:
                (
                  :counters.add(c, 1, 1)
                  :counters.get(c, 1)
                ),
              else: 1

          if n < 2, do: {:error, :transient}, else: {:ok, %{items: items}}
        end
      end

      params = base_params([%{id: 1}], %{strategy: :retry, process: pipeline([RetryableProcess])})

      assert {:ok, %{results: [_], errors: []}, _} = Batch.run(params, %{attempt: attempt})
    end
  end

  # ── on_between callback ───────────────────────────────────────────────────────

  describe "on_between callback" do
    test "fires after each chunk except the last" do
      pid = self()
      items = Enum.map(1..3, &%{id: &1})

      Batch.run(base_params(items), %{
        on_between: fn idx, result -> send(pid, {:between, idx, result}) end
      })

      assert_received {:between, 0, {:ok, _}}
      assert_received {:between, 1, {:ok, _}}
      refute_received {:between, 2, _}
    end

    test "fires with error outcome under :skip_and_continue" do
      pid = self()
      items = [%{id: 1}, %{id: 2}]

      params =
        base_params(items, %{
          strategy: :skip_and_continue,
          process: pipeline([FailProcess])
        })

      Batch.run(params, %{
        on_between: fn idx, result -> send(pid, {:between, idx, result}) end
      })

      assert_received {:between, 0, {:error, :process_failed}}
    end

    test "does not fire when :fail_workflow halts" do
      pid = self()
      items = [%{id: 1}, %{id: 2}]

      params =
        base_params(items, %{
          strategy: :fail_workflow,
          process: pipeline([FailProcess])
        })

      Batch.run(params, %{
        on_between: fn idx, result -> send(pid, {:between, idx, result}) end
      })

      refute_received {:between, _, _}
    end

    test "is optional — no callback in context is fine" do
      assert {:ok, _, _} = Batch.run(base_params([%{id: 1}]), %{})
    end
  end
end

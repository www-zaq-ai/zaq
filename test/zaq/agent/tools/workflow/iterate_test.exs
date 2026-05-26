defmodule Zaq.Agent.Tools.Workflow.IterateTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.Workflow.Iterate
  alias Zaq.Engine.Workflows.Test.{FilterContact, ProcessContact}

  # ── Inline pipeline stubs ────────────────────────────────────────────────────

  defmodule OkItemStep do
    def run(%{item: item} = _params, _ctx), do: {:ok, %{item: Map.put(item, :ok, true)}}
    def run(params, _ctx), do: {:ok, Map.put(params, :ok, true)}
  end

  defmodule FailItemStep do
    def run(_params, _ctx), do: {:error, :item_failed}
  end

  defmodule ConditionalItemStep do
    def run(%{item: %{fail: true}}, _ctx), do: {:error, :condition_failed}
    def run(%{item: item}, _ctx), do: {:ok, %{item: item}}
    def run(params, _ctx), do: {:ok, params}
  end

  defp pipeline(steps), do: Enum.map(steps, &{&1, %{}})

  defp base_params(items, extra \\ %{}) do
    Map.merge(
      %{
        items: items,
        __iterate_pipeline__: pipeline([OkItemStep]),
        __iterate_field__: :item,
        __iterate_mode__: :item
      },
      extra
    )
  end

  # ── :item mode ───────────────────────────────────────────────────────────────

  describe "run/2 — :item mode" do
    test "delivers %{field => item} to pipeline for each item" do
      items = [%{id: 1}, %{id: 2}, %{id: 3}]

      assert {:ok, %{results: results, errors: []}, _} =
               Iterate.run(base_params(items), %{})

      assert length(results) == 3
      assert Enum.all?(results, & &1.item.ok)
    end

    test "empty items list returns {:ok, %{results: [], errors: []}}" do
      assert {:ok, %{results: [], errors: []}, _} = Iterate.run(base_params([]), %{})
    end

    test "results are in original order" do
      items = [%{id: 1}, %{id: 2}, %{id: 3}]

      assert {:ok, %{results: results}, _} = Iterate.run(base_params(items), %{})
      assert Enum.map(results, & &1.item.id) == [1, 2, 3]
    end

    test "uses real action module (ProcessContact) for :item mode" do
      items = [%{name: "Jad"}, %{name: "ZAQ"}]

      params = %{
        items: items,
        __iterate_pipeline__: [{ProcessContact, %{}}],
        __iterate_field__: :contact,
        __iterate_mode__: :item
      }

      assert {:ok, %{results: results, errors: []}, _} = Iterate.run(params, %{})
      assert length(results) == 2
      assert Enum.all?(results, & &1.processed.done)
    end
  end

  # ── :list mode ───────────────────────────────────────────────────────────────

  describe "run/2 — :list mode" do
    test "delivers %{field => [item]} (wrapped) to pipeline for each item" do
      defmodule ListReceiver do
        def run(%{batch: batch}, _ctx), do: {:ok, %{received_list: batch}}
      end

      items = [%{id: 1}, %{id: 2}]

      params = %{
        items: items,
        __iterate_pipeline__: [{ListReceiver, %{}}],
        __iterate_field__: :batch,
        __iterate_mode__: :list
      }

      assert {:ok, %{results: results, errors: []}, _} = Iterate.run(params, %{})
      # Each item delivered as [item]
      assert Enum.map(results, & &1.received_list) == [[%{id: 1}], [%{id: 2}]]
    end
  end

  # ── no pipeline ──────────────────────────────────────────────────────────────

  describe "run/2 — no pipeline" do
    test "without pipeline each item is returned as-is" do
      items = [%{id: 1}, %{id: 2}]

      params = %{
        items: items,
        __iterate_pipeline__: [],
        __iterate_field__: :item,
        __iterate_mode__: :item
      }

      assert {:ok, %{results: [%{item: %{id: 1}}, %{item: %{id: 2}}], errors: []}, _} =
               Iterate.run(params, %{})
    end

    test "without iterate field, delivery is passed as raw item" do
      items = [%{id: 1}, %{id: 2}]

      params = %{
        items: items,
        __iterate_pipeline__: [],
        __iterate_mode__: :item
      }

      assert {:ok, %{results: [%{id: 1}, %{id: 2}], errors: []}, _} = Iterate.run(params, %{})
    end
  end

  # ── strategy: :skip_and_continue ─────────────────────────────────────────────

  describe "strategy: :skip_and_continue" do
    test "records errors and continues processing remaining items" do
      items = [%{id: 1}, %{fail: true}, %{id: 3}]

      params =
        base_params(items, %{
          strategy: :skip_and_continue,
          __iterate_pipeline__: pipeline([ConditionalItemStep])
        })

      assert {:ok, %{results: results, errors: errors}, _} = Iterate.run(params, %{})
      assert length(results) == 2
      assert [%{index: 1, reason: :condition_failed}] = errors
    end

    test "always returns :ok even when all items fail" do
      items = [%{fail: true}, %{fail: true}]

      params =
        base_params(items, %{
          strategy: :skip_and_continue,
          __iterate_pipeline__: pipeline([ConditionalItemStep])
        })

      assert {:ok, %{results: [], errors: errors}, _} = Iterate.run(params, %{})
      assert length(errors) == 2
    end

    test "is the default strategy" do
      items = [%{fail: true}]

      params = base_params(items, %{__iterate_pipeline__: pipeline([ConditionalItemStep])})

      assert {:ok, %{errors: [_]}, _} = Iterate.run(params, %{})
    end

    test "uses real FilterContact — inactive contact is skipped" do
      items = [%{name: "Active", active: true}, %{name: "Gone", active: false}]

      params = %{
        items: items,
        strategy: :skip_and_continue,
        __iterate_pipeline__: [{FilterContact, %{}}],
        __iterate_field__: :contact,
        __iterate_mode__: :item
      }

      assert {:ok, %{results: [_], errors: [%{index: 1, reason: :inactive}]}, _} =
               Iterate.run(params, %{})
    end
  end

  # ── strategy: :fail_workflow ─────────────────────────────────────────────────

  describe "strategy: :fail_workflow" do
    test "halts on first item error and returns {:error, reason}" do
      items = [%{fail: true}, %{id: 2}]

      params =
        base_params(items, %{
          strategy: :fail_workflow,
          __iterate_pipeline__: pipeline([ConditionalItemStep])
        })

      assert {:error, :condition_failed} = Iterate.run(params, %{})
    end

    test "does not process items after first failure" do
      counter = :counters.new(1, [])

      defmodule CountingItemStep do
        def run(%{item: %{fail: true}}, _ctx), do: {:error, :failed}

        def run(%{item: item}, ctx) do
          if c = Map.get(ctx, :counter), do: :counters.add(c, 1, 1)
          {:ok, %{item: item}}
        end
      end

      items = [%{fail: true}, %{id: 2}, %{id: 3}]

      params =
        base_params(items, %{
          strategy: :fail_workflow,
          __iterate_pipeline__: [{CountingItemStep, %{}}]
        })

      Iterate.run(params, %{counter: counter})
      assert :counters.get(counter, 1) == 0
    end

    test "returns binary error reason unchanged" do
      defmodule FailWithString do
        def run(_params, _ctx), do: {:error, "boom text"}
      end

      params =
        base_params([%{id: 1}], %{
          strategy: :fail_workflow,
          __iterate_pipeline__: [{FailWithString, %{}}]
        })

      assert {:error, "boom text"} = Iterate.run(params, %{})
    end

    test "formats non-atom/non-binary reason via inspect in logs for skip strategy" do
      defmodule FailWithTuple do
        def run(_params, _ctx), do: {:error, {:bad, 42}}
      end

      params =
        base_params([%{id: 1}], %{
          strategy: :skip_and_continue,
          __iterate_pipeline__: [{FailWithTuple, %{}}]
        })

      assert {:ok, %{errors: [%{reason: {:bad, 42}}]}, [logs: [log]]} = Iterate.run(params, %{})
      assert log.reason == "{:bad, 42}"
    end
  end

  # ── log trail ────────────────────────────────────────────────────────────────

  describe "log trail" do
    test "each successful item produces an item_ok log with at and duration_ms" do
      items = [%{id: 1}, %{id: 2}, %{id: 3}]

      assert {:ok, _, [logs: logs]} = Iterate.run(base_params(items), %{})
      assert length(logs) == 3

      assert Enum.all?(logs, fn log ->
               log.event == "item_ok" and log.duration_ms >= 0 and match?(%DateTime{}, log.at)
             end)
    end

    test "each failed item produces an item_error log with at and duration_ms" do
      items = [%{fail: true}, %{fail: true}]
      params = base_params(items, %{__iterate_pipeline__: pipeline([ConditionalItemStep])})

      assert {:ok, %{errors: [_, _]}, [logs: logs]} = Iterate.run(params, %{})
      assert length(logs) == 2

      assert Enum.all?(logs, fn log ->
               log.event == "item_error" and log.duration_ms >= 0 and match?(%DateTime{}, log.at)
             end)
    end

    test "mixed success and failure both produce timestamped logs" do
      items = [%{id: 1}, %{fail: true}, %{id: 3}]
      params = base_params(items, %{__iterate_pipeline__: pipeline([ConditionalItemStep])})

      assert {:ok, _, [logs: logs]} = Iterate.run(params, %{})
      assert length(logs) == 3
      assert Enum.any?(logs, &(&1.event == "item_ok"))
      assert Enum.any?(logs, &(&1.event == "item_error"))
    end

    test "logs are in original item order (index 0, 1, 2...)" do
      items = [%{id: 1}, %{id: 2}, %{id: 3}]

      assert {:ok, _, [logs: logs]} = Iterate.run(base_params(items), %{})
      assert Enum.map(logs, & &1.index) == [0, 1, 2]
    end

    test "empty items list returns empty logs" do
      assert {:ok, _, [logs: logs]} = Iterate.run(base_params([]), %{})
      assert logs == []
    end
  end

  # ── strategy: :retry ─────────────────────────────────────────────────────────

  describe "strategy: :retry" do
    test "skips item after 3 total attempts (max_retries exhausted)" do
      params =
        base_params([%{id: 1}], %{
          strategy: :retry,
          __iterate_pipeline__: pipeline([FailItemStep])
        })

      assert {:ok, %{results: [], errors: [%{index: 0, reason: :item_failed}]}, _} =
               Iterate.run(params, %{})
    end

    test "succeeds if retry succeeds" do
      attempt = :counters.new(1, [])

      defmodule RetryableItemStep do
        def run(%{item: item}, ctx) do
          c = Map.get(ctx, :attempt)

          n =
            if c,
              do:
                (
                  :counters.add(c, 1, 1)
                  :counters.get(c, 1)
                ),
              else: 1

          if n < 2, do: {:error, :transient}, else: {:ok, %{item: item}}
        end
      end

      params =
        base_params([%{id: 1}], %{
          strategy: :retry,
          __iterate_pipeline__: [{RetryableItemStep, %{}}]
        })

      assert {:ok, %{results: [_], errors: []}, _} = Iterate.run(params, %{attempt: attempt})
    end
  end
end

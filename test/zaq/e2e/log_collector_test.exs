defmodule Zaq.E2E.LogCollectorTest do
  use ExUnit.Case, async: false

  alias Zaq.E2E.LogCollector

  setup do
    LogCollector.clear()
    :ok
  end

  defp entry(level, message) do
    %{level: level, message: message, timestamp: DateTime.utc_now()}
  end

  test "push/1 stores entries" do
    LogCollector.push(entry(:info, "hello"))
    assert [%{level: :info, message: "hello"}] = LogCollector.recent()
  end

  test "recent/1 returns last N entries (most recent first)" do
    Enum.each(1..5, fn i -> LogCollector.push(entry(:info, "msg #{i}")) end)
    results = LogCollector.recent(limit: 3)
    assert length(results) == 3
    assert hd(results).message == "msg 5"
  end

  test "recent/1 filters by atom level" do
    LogCollector.push(entry(:info, "info msg"))
    LogCollector.push(entry(:error, "error msg"))
    results = LogCollector.recent(level: :error)
    assert length(results) == 1
    assert hd(results).message == "error msg"
  end

  test "recent/1 filters by string level" do
    LogCollector.push(entry(:warning, "warn msg"))
    LogCollector.push(entry(:info, "info msg"))
    results = LogCollector.recent(level: "warning")
    assert length(results) == 1
    assert hd(results).message == "warn msg"
  end

  test "clear/0 empties the collector" do
    LogCollector.push(entry(:info, "something"))
    LogCollector.clear()
    assert LogCollector.recent() == []
  end

  test "ring buffer caps at 500 entries" do
    Enum.each(1..510, fn i -> LogCollector.push(entry(:info, "msg #{i}")) end)
    entries = LogCollector.recent(limit: 600)
    assert length(entries) == 500
    assert hd(entries).message == "msg 510"
    assert List.last(entries).message == "msg 11"
  end
end

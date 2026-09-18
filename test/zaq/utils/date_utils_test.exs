defmodule Zaq.Utils.DateUtilsTest do
  use ExUnit.Case, async: true
  alias Zaq.Utils.DateUtils

  test "clock overrides distinguish a fixed instant from a live clock" do
    fixed = ~U[2026-09-14 12:00:00Z]
    assert DateUtils.now(now: fixed) == fixed
    clock = start_supervised!({Agent, fn -> fixed end})
    opts = [now: fn -> Agent.get(clock, & &1) end]
    assert DateUtils.now(opts) == fixed
    Agent.update(clock, &DateTime.add(&1, 60))
    assert DateUtils.now(opts) == ~U[2026-09-14 12:01:00Z]
    before = DateTime.utc_now()
    current = DateUtils.now([])
    assert DateTime.compare(current, before) != :lt
    assert DateTime.compare(current, DateTime.utc_now()) != :gt
  end

  test "timestamps retain second precision and unsupported values use the display fallback" do
    assert DateUtils.format_ts(~U[2026-09-14 12:00:00.123456Z]) == "2026-09-14 12:00:00Z"
    assert DateUtils.format_ts(~N[2026-09-14 12:00:00.123456]) == "2026-09-14 12:00:00"
    assert DateUtils.format_ts(nil) == "unknown time"
  end
end

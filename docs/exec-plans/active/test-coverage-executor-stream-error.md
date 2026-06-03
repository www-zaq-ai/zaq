# Test Coverage Plan: Zaq.Agent.Executor — Stream error branches + telemetry dimensions

**Target file:** `lib/zaq/agent/executor.ex`
**Uncovered lines:** 185, 188, 192, 199, 201, 203, 210, 291, 414
**Test file to edit:** `test/zaq/agent/executor_integration_test.exs`

---

## Uncovered code summary

| Lines | What they guard |
|-------|----------------|
| 184-199 | `{:error, %ReqLLM.Error.API.Stream{}}` branch **with** `status_message_id` set in `incoming.metadata` → suppressed stream error path (`suppressed_stream_error_result/1`) |
| 200-213 | Same stream error branch **without** `status_message_id` → normal error bubble path |
| 291 | Body of `suppressed_stream_error_result/1` — the map it builds (`error: false, suppressed: true`) |
| 414 | `ArgumentError` rescue inside `incoming_telemetry_dimensions/1` — hit when `telemetry_dimensions` metadata contains a binary key that is **not** an existing atom |

---

## Scenario 1 — Stream error, tokens already delivered (suppress bubble)

**Lines covered:** 185, 188, 192, 199, 291

### Setup
Add a new stub factory module inside the test module:

```elixir
defmodule StubFactoryStreamError do
  def ask_with_config(_server, _content, _configured_agent, _opts \\ []), do: {:ok, :request}

  def await(:request, _opts) do
    {:error, ReqLLM.Error.API.Stream.exception(reason: "stream closed mid-flight", cause: nil)}
  end

  def answering_configured_agent, do: %{id: :answering, name: "answering"}
end
```

### Test

```elixir
test "suppresses stream error when status_message_id is already set in incoming metadata" do
  incoming = %Incoming{
    content: "hello",
    channel_id: "bo-test",
    provider: :web,
    # simulate tokens already delivered: status_message_id is present
    metadata: %{status_message_id: "msg-123"}
  }

  outgoing =
    Executor.run(incoming,
      agent_id: "stub",
      agent_module: StubAgent,
      server_manager_module: StubServerManager,
      factory_module: StubFactoryStreamError
    )

  # Suppressed path returns error: false and suppressed: true
  assert outgoing.metadata.error == false
  assert outgoing.metadata[:suppressed] == true
  assert outgoing.body == ""
end
```

**Why this works:** `get_in(incoming.metadata, [:status_message_id])` returns `"msg-123"` (not nil), so the `if` branch on line 185 is taken, executing lines 188, 192–197, 199, and the `suppressed_stream_error_result/1` body (line 291).

---

## Scenario 2 — Stream error, no tokens delivered (error bubble)

**Lines covered:** 200-201, 203, 210

### Test

```elixir
test "surfaces stream error when no status_message_id is set in incoming metadata" do
  incoming = %Incoming{
    content: "hello",
    channel_id: "bo-test",
    provider: :web
    # metadata not set → no status_message_id
  }

  outgoing =
    Executor.run(incoming,
      agent_id: "stub",
      agent_module: StubAgent,
      server_manager_module: StubServerManager,
      factory_module: StubFactoryStreamError
    )

  # Normal error path
  assert outgoing.metadata.error == true
  assert outgoing.body =~ "something went wrong"
end
```

**Why this works:** `incoming.metadata` is `%{}` (default for `Incoming`), so `get_in/2` returns `nil`. The `else` branch (lines 200–213) runs.

**Note:** verify `%Incoming{}` default for `metadata` — if it is `nil` rather than `%{}`, wrap it: `metadata: %{}`.

---

## Scenario 3 — `incoming_telemetry_dimensions` drops unknown binary key

**Line covered:** 414

### Test

```elixir
test "telemetry_dimensions silently drops unknown string keys in incoming metadata" do
  incoming = %Incoming{
    content: "hi",
    channel_id: "ch",
    provider: :web,
    metadata: %{
      "telemetry_dimensions" => %{
        # "definitely_not_an_existing_atom_zxqy" will never be a known atom
        "definitely_not_an_existing_atom_zxqy_#{System.unique_integer()}" => "value",
        # known atom key — should pass through
        "execution_path" => "custom_agent"
      }
    }
  }

  outgoing =
    Executor.run(incoming,
      agent_id: "stub",
      agent_module: StubAgent,
      server_manager_module: StubServerManager,
      factory_module: StubFactoryAnswer
    )

  # Run succeeds; the unknown key was silently dropped, no crash
  assert outgoing.metadata.error == false
end
```

**Why this works:** `incoming_telemetry_dimensions/1` calls `String.to_existing_atom/1` on the unknown key. That raises `ArgumentError`, which is rescued on line 414, and the accumulator skips the key.

---

## Reuse notes

- `StubAgent`, `StubServerManager`, `StubFactoryAnswer` already exist in the test file — reuse them.
- Only `StubFactoryStreamError` is new.
- The `ReqLLM.Error.API.Stream` struct uses `Splode.Error` — construct with `.exception(reason: ..., cause: nil)`.
- No real HTTP stub needed for any of these three tests; all three use the injected factory path.

---

## Checklist

- [ ] Add `StubFactoryStreamError` module inside `ExecutorIntegrationTest`
- [ ] Add Scenario 1 test (`suppresses stream error when status_message_id is set`)
- [ ] Add Scenario 2 test (`surfaces stream error when no status_message_id`)
- [ ] Add Scenario 3 test (`silently drops unknown binary telemetry dimension keys`)
- [ ] Run `mix test test/zaq/agent/executor_integration_test.exs` and confirm all pass
- [ ] Run `mix q` to confirm no regressions

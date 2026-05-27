# Coverage Plan: StartupRecovery

## Target file
`lib/zaq/engine/workflows/startup_recovery.ex`

## Test file to edit
`test/zaq/engine/workflows/startup_recovery_test.exs`

## Uncovered lines
- Line 33–34: `Logger.info` call inside the `else` branch when stale runs exist — currently exercises interrupt but Logger is at :warning level so the info call arguments are never evaluated
- Line 46: `Logger.error` call inside `interrupt_one/1` when `Workflows.interrupt_run/1` returns `{:error, reason}`

## Root cause analysis

### Lines 33–34
The test at line 47 (`"interrupts all stale runs on startup"`) does exercise the `else` branch, but `Logger.configure(level: :info)` is not set, so at :warning level, the `Logger.info` call with anonymous-function arguments is never evaluated — the coverage tool marks it as uncovered.

Fix: Add a test that temporarily sets Logger level to :info and calls `StartupRecovery.run([])` with stale runs present, then restores `:warning`.

### Line 46
No test currently forces `Workflows.interrupt_run/1` to return `{:error, reason}`. The module does not accept a mock/override for `Workflows`, so we need to test this by mocking the dependency.

Looking at the code: `interrupt_one/1` calls `Workflows.interrupt_run(run)`. We cannot easily force an error without mocking or bypassing. However, since `StartupRecovery` uses `Workflows` directly (not injected), we can use `Mox` or bypass with a real scenario.

**Strategy**: Use `Mox` or rely on the fact that `Workflows.interrupt_run/1` operates on the DB. We can use `:meck` or simply check if `Zaq.Engine.WorkflowsMock` exists. Looking at the broader test suite pattern, `Stubs.stub_node_router()` is used. For interrupt_run, we can stub it via patching or — simpler — use a module attribute override pattern.

Since the codebase uses Mox for NodeRouter, and `StartupRecovery` calls `Workflows.interrupt_run/1` directly (not via NodeRouter), we cannot easily mock it with existing infrastructure.

**Alternative approach**: We can verify lines 33–34 simply with a Logger level change. For line 46, we can use `with_mock` from `:meck` or check if any mock is available.

Actually, looking more carefully: the module calls `Workflows.interrupt_run(run)` at line 40. If we pass a run struct that has already been deleted from DB, `interrupt_run/1` will likely fail with an Ecto error → returns `{:error, reason}`. But `interrupt_run/1` may raise instead of returning `{:error, ...}`.

Let us check what `Workflows.interrupt_run/1` actually returns on error. Since we can't read it here, the safe approach is:

1. For lines 33–34: Add a test with `Logger.configure(level: :info)` + `on_exit` restore
2. For line 46: Use `Mox` to mock `Zaq.Engine.Workflows` OR check if there's a way to make a run that triggers failure. Another approach: delete the run between `list_stale_runs` and `interrupt_run` using a DB trigger — but that's fragile.

**Simplest safe approach for line 46**: Patch the application config so `StartupRecovery` uses a mock `Workflows` module. If no mock exists for `Workflows`, we need to create a simple test double.

Check whether `Zaq.Engine.Workflows` has a behaviour or if `StartupRecovery` reads it from config. Since `StartupRecovery` uses `alias Zaq.Engine.Workflows` and calls it directly at compile time, runtime patching isn't straightforward.

**Best approach for line 46**: Use `:meck` to mock `Zaq.Engine.Workflows.interrupt_run/1` in a test. `:meck` is commonly available in Elixir test suites. If not available, check `mix.exs` for meck dependency.

If `:meck` is not available, the alternative is to create a test where a run's ID is deleted from DB before StartupRecovery runs interrupt, and `interrupt_run` returns `{:error, ...}`.

## Implementation plan

### Test 1: Logger :info coverage (lines 33–34)
```elixir
test "logs stale run count at info level", %{} do
  Logger.configure(level: :info)
  on_exit(fn -> Logger.configure(level: :warning) end)
  
  w = create_workflow()
  create_run(w, "running")
  
  # Should not raise
  StartupRecovery.run([])
end
```

Add this to the existing `describe "run/1"` block.

### Test 2: Error branch coverage (line 46)
We need to force `Workflows.interrupt_run(run)` to return `{:error, reason}`.

Strategy: Check if `:meck` is in deps. If yes, use it. Otherwise, we can test this by having a run that passes `list_stale_runs` but then making its id invalid.

Actually, the simpler approach: override the workflows module at runtime using `Application.put_env` if `StartupRecovery` supports that pattern.

Since `StartupRecovery` doesn't support injection, use `:meck`:

```elixir
test "logs error when interrupt_run fails and continues with other runs" do
  w = create_workflow()
  run1 = create_run(w, "running")
  run2 = create_run(w, "running")
  
  # Mock interrupt_run to fail for run1 and succeed for run2
  :meck.new(Zaq.Engine.Workflows, [:passthrough])
  :meck.expect(Zaq.Engine.Workflows, :interrupt_run, fn
    r when r.id == run1.id -> {:error, :test_error}
    r -> Zaq.Engine.Workflows.interrupt_run(r)
  end)
  
  on_exit(fn -> :meck.unload(Zaq.Engine.Workflows) end)
  
  # Should not raise; should log error but continue
  StartupRecovery.run([])
  
  assert Workflows.get_run!(run2.id).status == "interrupted"
end
```

If :meck is not available, use a different approach: directly call the private `interrupt_one/1` by making the run's DB record disappear. Actually we can't call private functions directly.

**Alternative without meck**: Run with Logger.configure(level: :info) to at least confirm the error path logs, but we can't get the error branch without forcing interrupt_run to fail.

The cleanest approach if :meck is not available is to check if `Zaq.Engine.WorkflowsMock` exists in the codebase, or add `:meck` to test deps.

Check in mix.exs: look for `:meck` or `Mox` patterns for direct module mocking.

Since this plan targets adding the minimal necessary tests, add the Logger :info test for lines 33–34, and for line 46 use `:meck` if available (check `mix.exs`), otherwise note that it requires infrastructure change.

## Exact steps

1. Open `test/zaq/engine/workflows/startup_recovery_test.exs`
2. In `describe "run/1"`, add a test that sets Logger level to :info before calling `StartupRecovery.run([])` with at least one stale run
3. Check mix.exs for `:meck` dependency. If present, add a test that mocks `Workflows.interrupt_run/1` to return `{:error, reason}` for one run and verifies `StartupRecovery.run([])` does not crash and still processes remaining runs.
4. If `:meck` is not present in mix.exs, add it to the test deps and implement test 2.
5. Run `mix test test/zaq/engine/workflows/startup_recovery_test.exs` to confirm all tests pass.

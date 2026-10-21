const { test } = require("node:test")
const assert = require("node:assert/strict")
const { readFileSync } = require("node:fs")
const vm = require("node:vm")

// Hook unit tests only: no browser, server, real clock or real interval.
function mount(state = "running", identity = "native") {
  let now = 0
  let nextTimer = 0
  const intervals = new Map()
  const duration = { textContent: "~0 s" }
  const el = {
    dataset: { toolState: state, toolStepId: identity },
    querySelector: () => duration
  }
  const source = readFileSync("assets/js/hooks/tool_step_timer.js", "utf8")
  const hooks = vm.runInNewContext(source.replace("export const", "const") + "; ({ToolStepTimer})", {
    performance: { now: () => now },
    setInterval: fn => { intervals.set(++nextTimer, fn); return nextTimer },
    clearInterval: id => intervals.delete(id)
  })
  const hook = { ...hooks.ToolStepTimer, el }
  hook.mounted()
  return {
    hook, el, duration, intervals,
    advance: milliseconds => { now += milliseconds; intervals.forEach(fn => fn()) }
  }
}

test("elapsed time increases monotonically and ordinary patches never reset its origin", () => {
  const fixture = mount()
  assert.equal(fixture.duration.textContent, "~0 s")
  fixture.advance(2100)
  assert.equal(fixture.duration.textContent, "~2 s")
  fixture.duration.textContent = "~0 s" // server markup patched, same invocation
  fixture.hook.updated()
  assert.equal(fixture.duration.textContent, "~2 s")
  assert.equal(fixture.intervals.size, 1)
  fixture.advance(1000)
  assert.equal(fixture.duration.textContent, "~3 s")
  fixture.hook.destroyed()
  assert.equal(fixture.intervals.size, 0)
})

test("known terminal duration replaces the estimate and cannot be overwritten by a timer", () => {
  for (const state of ["succeeded", "failed"]) {
    const fixture = mount()
    fixture.advance(4000)
    const pendingTick = [...fixture.intervals.values()][0]
    fixture.el.dataset.toolState = state
    fixture.duration.textContent = "1.2 s"
    fixture.hook.updated()
    pendingTick() // a queued callback must not replace the server-owned duration
    assert.equal(fixture.intervals.size, 0)
    assert.equal(fixture.duration.textContent, "1.2 s")
  }
})

test("unknown stops timing without inventing a measured duration", () => {
  const fixture = mount()
  fixture.advance(4000)
  fixture.el.dataset.toolState = "unknown"
  fixture.el.querySelector = () => null // server removes unmeasured duration
  fixture.hook.updated()
  assert.equal(fixture.intervals.size, 0)
  assert.equal(fixture.el.querySelector(), null)
})

test("disconnect pauses ticks and reconnect preserves the observed origin with one timer", () => {
  const fixture = mount()
  fixture.advance(2000)
  fixture.hook.disconnected()
  assert.equal(fixture.intervals.size, 0)
  fixture.advance(3000)
  fixture.hook.reconnected()
  fixture.hook.reconnected()
  assert.equal(fixture.intervals.size, 1)
  assert.equal(fixture.duration.textContent, "~5 s")
  fixture.hook.destroyed()
  assert.equal(fixture.intervals.size, 0)
})

test("different invocations and genuine remounts have independent observed timers", () => {
  const fixture = mount()
  fixture.advance(5000)
  fixture.el.dataset.toolStepId = "another-native-call"
  fixture.hook.updated()
  assert.equal(fixture.duration.textContent, "~0 s")
  assert.equal(fixture.intervals.size, 1)
  const another = mount()
  fixture.advance(1000)
  assert.equal(another.duration.textContent, "~0 s")
  fixture.hook.destroyed()
  another.hook.destroyed()
})

test("terminal history and malformed state never start a live clock", () => {
  for (const state of ["succeeded", "failed", "unknown", null, "invalid"]) {
    const fixture = mount(state)
    assert.equal(fixture.intervals.size, 0)
    fixture.hook.destroyed()
  }
})

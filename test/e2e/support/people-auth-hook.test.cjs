const { test } = require("node:test")
const assert = require("node:assert/strict")
const { readFileSync } = require("node:fs")
const vm = require("node:vm")
const { resolve } = require("node:path")
const { pathToFileURL } = require("node:url")

function mount(deadline) {
  let now = Date.parse("2026-09-14T12:00:00Z")
  const intervals = new Map()
  let nextTimer = 0
  const listeners = new Map()
  const inputListeners = new Map()
  const input = {
    value: "",
    addEventListener: (name, fn) => inputListeners.set(name, fn),
    removeEventListener: name => inputListeners.delete(name)
  }
  const resend = { disabled: false }
  const signIn = { disabled: false }
  const caption = { textContent: "" }
  const expiry = { textContent: "" }
  const el = {
    dataset: { expiresAt: "2026-09-14T12:05:00Z", resendAvailableAt: deadline },
    querySelector: selector => ({
      "input[autocomplete='one-time-code']": input,
      "#people-resend": resend,
      "[data-resend-countdown]": caption,
      "[data-countdown]": expiry
    })[selector],
    querySelectorAll: () => [resend, signIn],
    addEventListener: (name, fn) => listeners.set(name, fn),
    removeEventListener: name => listeners.delete(name)
  }
  const source = readFileSync("assets/js/hooks/people_auth.js", "utf8")
  const hooks = vm.runInNewContext(source.replaceAll("export const", "const") + "; ({PeopleOTP, PeopleAuthForm})", {
    Date: { parse: Date.parse, now: () => now },
    setInterval: fn => { intervals.set(++nextTimer, fn); return nextTimer },
    clearInterval: id => intervals.delete(id)
  }, { filename: pathToFileURL(resolve("assets/js/hooks/people_auth.js")).href })
  const hook = { ...hooks.PeopleOTP, el }
  hook.mounted()
  return { hook, formHook: { ...hooks.PeopleAuthForm, el }, el, input, inputListeners, listeners, resend, signIn, caption, intervals,
    advance: seconds => { now += seconds * 1000; intervals.forEach(fn => fn()) } }
}

test("deadline updates, missing legacy attributes and remount never reuse stale timers", () => {
  const fixture = mount("2026-09-14T12:01:00Z")
  const { hook, el, resend, caption, intervals } = fixture
  fixture.advance(15)
  assert.equal(caption.textContent, "Resend in 00:45")
  el.dataset.resendAvailableAt = "2026-09-14T12:01:15Z"
  hook.updated()
  assert.equal(caption.textContent, "Resend in 01:00")
  assert.equal(resend.disabled, true)
  hook.disconnected()
  assert.equal(intervals.size, 0)
  hook.reconnected()
  hook.reconnected()
  assert.equal(intervals.size, 1)
  fixture.advance(60)
  assert.equal(caption.textContent, "Resend code")
  assert.equal(resend.disabled, false)
  hook.destroyed()
  assert.equal(intervals.size, 0)
  assert.equal(fixture.listeners.size, 0)
  assert.equal(fixture.inputListeners.size, 0)
  const legacy = mount(undefined)
  assert.equal(legacy.resend.disabled, false)
  assert.equal(legacy.caption.textContent, "Resend code")
  legacy.hook.destroyed()
})

test("submission cannot be undone by expiry, attribute patches or reconnection", () => {
  const fixture = mount("2026-09-14T12:01:00Z")
  fixture.listeners.get("submit")()
  fixture.advance(60)
  assert.equal(fixture.resend.disabled, true)
  assert.equal(fixture.signIn.disabled, true)
  // Simulate a server patch restoring the button's original enabled markup.
  fixture.signIn.disabled = false
  fixture.hook.updated()
  assert.equal(fixture.signIn.disabled, true)
  fixture.hook.disconnected()
  fixture.hook.reconnected()
  assert.equal(fixture.resend.disabled, true)
  fixture.hook.destroyed()
})

test("code formatting preserves invalid characters for authoritative verification", () => {
  const fixture = mount(undefined)
  fixture.input.value = "12345678"
  fixture.inputListeners.get("input")()
  assert.equal(fixture.input.value, "1234-5678")
  fixture.input.value = "123x5678"
  fixture.inputListeners.get("input")()
  assert.equal(fixture.input.value, "123x5678")
  fixture.hook.destroyed()
})

test("email form disables submissions and removes its listener on destruction", () => {
  const fixture = mount(undefined)
  fixture.hook.destroyed()
  fixture.formHook.mounted()
  fixture.listeners.get("submit")()
  assert.equal(fixture.signIn.disabled, true)
  fixture.formHook.destroyed()
  assert.equal(fixture.listeners.size, 0)
})

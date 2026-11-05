const { test } = require("node:test")
const assert = require("node:assert/strict")
const { readFileSync } = require("node:fs")
const vm = require("node:vm")

function fixture(dataset = {}, disabled = false) {
  const calls = []
  const timers = []
  const element = () => {
    const classes = new Set(["hidden"])
    return {
      dataset: {}, style: {}, listeners: {}, value: "", textContent: "", offsetHeight: 100,
      classList: { add: c => classes.add(c), remove: c => classes.delete(c), contains: c => classes.has(c) },
      addEventListener(name, fn) { this.listeners[name] = fn },
      setAttribute() {}, focus() {},
      getBoundingClientRect: () => ({ width: 200, left: 0, top: 0, bottom: 30 }),
      dispatchEvent() {}
    }
  }
  const trigger = element()
  trigger.disabled = disabled
  const search = element()
  const panel = element()
  const hidden = element()
  const label = element()
  const create = element()
  const createLabel = element()
  const clear = dataset.clearable === "true" ? element() : null
  create.dataset.createEvent = "create_value"
  create.querySelector = () => createLabel
  const option = element()
  option.dataset = { selectOption: "Paris", selectValue: "Paris", selectDisabled: "false" }
  option.scrollWidth = 40
  const list = element()
  list.querySelectorAll = () => [option]
  const nodes = {
    "[data-select-trigger]": trigger, "[data-select-search]": search,
    "[data-select-panel]": panel, "[data-select-list]": list,
    "[data-select-label]": label, "[data-select-create]": create,
    "[data-select-clear]": clear,
    "input[type=hidden][data-select-value]": hidden
  }
  const root = { dataset, querySelector: selector => nodes[selector], contains: () => true }
  const source = readFileSync("assets/js/hooks/searchable_select_hook.js", "utf8")
  const hook = vm.runInNewContext(source.replace("export const SearchableSelectHook", "const SearchableSelectHook") + ";SearchableSelectHook", {
    window: { innerHeight: 800, addEventListener() {}, removeEventListener() {} },
    document: { addEventListener() {}, removeEventListener() {} },
    setTimeout: fn => timers.push(fn), clearTimeout() {}, Event
  })
  hook.el = root
  hook.pushEvent = (event, params) => calls.push({ event, params: JSON.parse(JSON.stringify(params)) })
  hook.pushEventTo = (target, event, params) => calls.push({ target, event, params: JSON.parse(JSON.stringify(params)) })
  hook.mounted()
  const event = { preventDefault() {}, stopPropagation() {} }
  return { hook, calls, timers, trigger, search, create, createLabel, option, event, clear }
}

test("component picker routes search and creation with label identity", () => {
  const f = fixture({ eventTarget: "12", eventContext: '{"label_id":"34"}', serverSearch: "search_values", createOnNoExactMatch: "true" })
  f.trigger.listeners.click(f.event)
  assert.deepEqual(f.calls[0], { target: 12, event: "search_values", params: { label_id: "34", query: "" } })
  f.search.value = "Par"
  f.search.listeners.input(f.event)
  f.timers.pop()()
  assert.deepEqual(f.calls[1], { target: 12, event: "search_values", params: { label_id: "34", query: "Par" } })
  f.hook.updated()
  assert.equal(f.create.classList.contains("hidden"), false)
  f.create.listeners.click(f.event)
  assert.deepEqual(f.calls[2], { target: 12, event: "create_value", params: { label_id: "34", name: "Par" } })
  f.hook.destroyed()
})

test("existing consumers retain parent events and default creation rules", () => {
  const f = fixture()
  f.trigger.listeners.click(f.event)
  f.search.value = "Par"
  f.search.listeners.input(f.event)
  assert.equal(f.create.classList.contains("hidden"), true)
  f.search.value = "London"
  f.search.listeners.input(f.event)
  f.create.listeners.click(f.event)
  assert.deepEqual(f.calls, [{ event: "create_value", params: { name: "London" } }])
  f.hook.destroyed()
})

test("disabled picker cannot open or initiate a search", () => {
  const f = fixture({ serverSearch: "search_values" }, true)
  f.trigger.listeners.click(f.event)
  assert.equal(f.hook._open, false)
  assert.deepEqual(f.calls, [])
  f.hook.destroyed()
})


test("first value can be created without a server DOM update", () => {
  const f = fixture({ eventTarget: "12", eventContext: '{"label_id":"34"}', serverSearch: "search_values", createOnNoExactMatch: "true" })
  f.option.dataset = { selectOption: "No value", selectValue: "", selectDisabled: "false" }
  f.trigger.listeners.click(f.event)
  f.search.value = "Engineering"
  f.search.listeners.input(f.event)
  assert.equal(f.option.style.display, "none")
  assert.equal(f.create.classList.contains("hidden"), false)
  assert.equal(f.createLabel.textContent, '+ Add "Engineering"')
  // The backend returns [] again: no updated() callback occurs.
  f.timers.pop()()
  f.create.listeners.click(f.event)
  assert.deepEqual(f.calls.at(-1), {
    target: 12, event: "create_value", params: { label_id: "34", name: "Engineering" }
  })
  f.hook.destroyed()
})

test("server-search create visibility follows every keystroke without a patch", () => {
  const f = fixture({ serverSearch: "search_values", createOnNoExactMatch: "true" })
  f.trigger.listeners.click(f.event)
  for (const [query, hidden] of [["Berlin", false], ["Paris", true], ["", true], ["Rome", false]]) {
    f.search.value = query
    f.search.listeners.input(f.event)
    assert.equal(f.create.classList.contains("hidden"), hidden)
  }
  f.hook.destroyed()
})

test("Enter creates the typed value instead of selecting a partial match", () => {
  const f = fixture({ createOnNoExactMatch: "true" })
  f.trigger.listeners.click(f.event)
  f.search.value = "Par"
  f.search.listeners.input(f.event)
  f.search.listeners.keydown({ ...f.event, key: "Enter" })
  assert.deepEqual(f.calls, [{ event: "create_value", params: { name: "Par" } }])
  assert.equal(f.hook._hidden().value, "")
  f.hook.destroyed()
})

test("Enter still selects exact matches and preserves default partial matching", () => {
  for (const [dataset, query] of [[{ createOnNoExactMatch: "true" }, "Paris"], [{}, "Par"]]) {
    const f = fixture(dataset)
    f.trigger.listeners.click(f.event)
    f.search.value = query
    f.search.listeners.input(f.event)
    f.search.listeners.keydown({ ...f.event, key: "Enter" })
    assert.equal(f.hook._hidden().value, "Paris")
    assert.deepEqual(f.calls, [])
    f.hook.destroyed()
  }
})

test("clear emits the normal form events, closes the picker and restores focus", () => {
  const f = fixture({ clearable: "true", emptyLabel: "No value" })
  const events = []
  let focused = false
  f.hook._hidden().value = "Paris"
  f.hook._hidden().dispatchEvent = event => events.push(event.type)
  f.trigger.focus = () => { focused = true }
  f.trigger.listeners.click(f.event)
  f.clear.listeners.click(f.event)
  assert.equal(f.hook._hidden().value, "")
  assert.equal(f.hook._labelEl().textContent, "No value")
  assert.deepEqual(events, ["input", "change"])
  assert.equal(f.clear.hidden, true)
  assert.equal(f.hook._open, false)
  assert.equal(focused, true)
  f.hook.destroyed()
})

test("disabled clearable picker cannot clear a value", () => {
  const f = fixture({ clearable: "true" }, true)
  f.hook._hidden().value = "Paris"
  f.clear.listeners.click(f.event)
  assert.equal(f.hook._hidden().value, "Paris")
  f.hook.destroyed()
})

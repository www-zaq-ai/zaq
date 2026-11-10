const { test } = require("node:test")
const assert = require("node:assert/strict")
const { readFileSync } = require("node:fs")
const { resolve } = require("node:path")
const vm = require("node:vm")

function mount() {
  const documentListeners = new Map()
  const windowListeners = new Map()
  const triggerListeners = new Map()
  const searchListeners = new Map()
  const classes = new Set(["hidden"])
  const attributes = new Map()
  const option = { dataset: { selectOption: "Catalog", selectValue: "108" }, style: {} }
  const panel = {
    style: {},
    offsetHeight: 100,
    classList: { add: value => classes.add(value), remove: value => classes.delete(value) }
  }
  const trigger = {
    getBoundingClientRect: () => ({ left: 10, top: 10, bottom: 40, width: 200 }),
    setAttribute: (name, value) => attributes.set(name, value),
    addEventListener: (name, fn) => triggerListeners.set(name, fn)
  }
  const search = {
    value: "",
    focus() {},
    addEventListener: (name, fn) => searchListeners.set(name, fn)
  }
  const list = {
    style: {},
    querySelectorAll: () => [option],
    addEventListener() {}
  }
  const elements = {
    "[data-select-trigger]": trigger,
    "[data-select-panel]": panel,
    "[data-select-search]": search,
    "[data-select-list]": list
  }
  const el = {
    dataset: {},
    querySelector: selector => elements[selector] || null,
    contains: target => Object.values(elements).includes(target) || target === option
  }
  const path = resolve(__dirname, "../../../assets/js/hooks/searchable_select_hook.js")
  const source = readFileSync(path, "utf8")
  const hooks = vm.runInNewContext(
    source.replace("export const", "const") + "; SearchableSelectHook",
    {
      document: {
        addEventListener: (name, fn) => documentListeners.set(name, fn),
        removeEventListener: name => documentListeners.delete(name)
      },
      window: {
        innerHeight: 720,
        addEventListener: (name, fn) => windowListeners.set(name, fn),
        removeEventListener: name => windowListeners.delete(name)
      },
      clearTimeout() {}
    },
    { filename: path }
  )
  const hook = { ...hooks, el }
  hook.mounted()
  triggerListeners.get("click")({ preventDefault() {} })
  search.value = "Catalog"
  searchListeners.get("input")({ stopPropagation() {} })
  return { hook, classes, attributes, search, option, documentListeners, windowListeners }
}

test("synthetic outside clicks from flash auto-dismiss preserve the open dropdown and search", () => {
  const fixture = mount()
  fixture.documentListeners.get("click")({ target: {}, isTrusted: false })
  assert.equal(fixture.hook._open, true)
  assert.equal(fixture.classes.has("hidden"), false)
  assert.equal(fixture.attributes.get("aria-expanded"), "true")
  assert.equal(fixture.search.value, "Catalog")
  assert.equal(fixture.hook._search, "Catalog")
  fixture.hook.destroyed()
})

test("trusted outside clicks still dismiss the dropdown", () => {
  const fixture = mount()
  fixture.documentListeners.get("click")({ target: {}, isTrusted: true })
  assert.equal(fixture.hook._open, false)
  assert.equal(fixture.classes.has("hidden"), true)
  assert.equal(fixture.attributes.get("aria-expanded"), "false")
  fixture.hook.destroyed()
  assert.equal(fixture.documentListeners.size, 0)
  assert.equal(fixture.windowListeners.size, 0)
})

test("trusted inside clicks do not dismiss before option selection", () => {
  const fixture = mount()
  fixture.documentListeners.get("click")({ target: fixture.option, isTrusted: true })
  assert.equal(fixture.hook._open, true)
  assert.equal(fixture.classes.has("hidden"), false)
  fixture.hook.destroyed()
})

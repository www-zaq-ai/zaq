const { test } = require("node:test")
const assert = require("node:assert/strict")
const { readFileSync } = require("node:fs")
const vm = require("node:vm")

const source = readFileSync("assets/js/storybook_iframes.js", "utf8")
const install = vm.runInNewContext(source.replace("export function", "function") + "; installStorybookIframeResize")

function fixture() {
  let listener
  const pending = []
  const document = { addEventListener(name, callback, capture) {
    assert.equal(name, "load")
    assert.equal(capture, true)
    listener = callback
  } }
  install(document, (callback, delay) => {
    assert.equal(delay, 100)
    pending.push(callback)
  })
  const frame = {
    tagName: "IFRAME",
    isConnected: true,
    contentDocument: { body: { scrollHeight: 120 } },
    style: {},
    closest: () => ({}),
    inline: "o.style.height=o.contentWindow.document.body.scrollHeight+'px'",
    getAttribute() { return this.inline },
    removeAttribute(name) { assert.equal(name, "onload"); this.inlineRemoved = true; this.inline = null }
  }
  return { frame, pending, load: target => listener({ target }) }
}

test("Storybook frames retain immediate and delayed content-height measurement", () => {
  const { frame, pending, load } = fixture()
  load(frame)
  assert.equal(frame.inlineRemoved, true)
  assert.equal(frame.style.height, "120px")
  assert.equal(pending.length, 1)
  frame.contentDocument.body.scrollHeight = 240
  pending[0]()
  assert.equal(frame.style.height, "240px")
  load(frame)
  assert.equal(pending.length, 2)
})

test("a removed frame is not dereferenced by the delayed resize", () => {
  const { frame, pending, load } = fixture()
  load(frame)
  frame.isConnected = false
  Object.defineProperty(frame, "contentDocument", { get() { throw new Error("Detached document accessed") } })
  assert.doesNotThrow(pending[0])
  assert.equal(frame.style.height, "120px")
})

test("unavailable frame documents and bodies are safe during loading", () => {
  for (const contentDocument of [null, { body: null }]) {
    const { frame, pending, load } = fixture()
    frame.contentDocument = contentDocument
    assert.doesNotThrow(() => load(frame))
    assert.doesNotThrow(pending[0])
    assert.equal(frame.style.height, undefined)
  }
})

test("other resource loads and custom iframe handlers are left untouched", () => {
  for (const override of [{ tagName: "IMG" }, { closest: () => null }, { getAttribute: () => "customHandler()" }]) {
    const { frame, pending, load } = fixture()
    Object.assign(frame, override)
    load(frame)
    assert.equal(frame.inlineRemoved, undefined)
    assert.equal(pending.length, 0)
  }
})

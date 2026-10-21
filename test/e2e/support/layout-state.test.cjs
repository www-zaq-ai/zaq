const { test } = require("node:test")
const assert = require("node:assert/strict")
const { readFileSync } = require("node:fs")
const vm = require("node:vm")

const source = readFileSync("assets/js/layout.js", "utf8")
const preserveSidebarState = vm.runInNewContext(source.replace("export function", "function") + "; preserveSidebarState")

function element(id, names) {
  const classes = new Set(names)
  return { id, classes, classList: {
    contains: name => classes.has(name),
    toggle: (name, enabled) => enabled ? classes.add(name) : classes.delete(name)
  } }
}

test("sidebar and main retain matching client collapse state across server patches", () => {
  for (const id of ["bo-sidebar", "bo-main"]) {
    for (const collapsed of [true, false]) {
      const from = element(id, collapsed ? ["collapsed", "old-class"] : ["old-class"])
      const to = element(id, ["server-class", ...(!collapsed ? ["collapsed"] : [])])
      preserveSidebarState(from, to)
      assert.equal(to.classes.has("collapsed"), collapsed)
      assert.equal(to.classes.has("server-class"), true)
      assert.equal(to.classes.has("old-class"), false)
    }
  }
})

test("ordinary elements retain only server-owned classes", () => {
  const from = element("chat-messages", ["collapsed"])
  const to = element("chat-messages", ["server-class"])
  preserveSidebarState(from, to)
  assert.deepEqual([...to.classes], ["server-class"])
})

test("main app explicitly opts into the shared tool timer and layout callback", () => {
  const app = readFileSync("assets/js/app.js", "utf8")
  assert.match(app, /ToolStepTimer:\s*liveViewHooks\.ToolStepTimer/)
  assert.match(app, /onBeforeElUpdated:\s*preserveSidebarState/)
})

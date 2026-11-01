const { test } = require("node:test")
const assert = require("node:assert/strict")
const { readFileSync } = require("node:fs")
const vm = require("node:vm")

const source = readFileSync("assets/js/liveview_hooks.js", "utf8")
const imports = [...source.matchAll(/^import (.+) from .+$/gm)]
const bindings = Object.fromEntries(imports.flatMap(([, names]) =>
  names.replace(/[{}]/g, "").split(",").map(name => [name.trim().split(/\s+as\s+/).pop(), {}])
))
const hooks = vm.runInNewContext(
  source.replace(/^import .+$/gm, "").replace("export const liveViewHooks", "const liveViewHooks") + ";liveViewHooks",
  bindings
)

test("disclosure preserves user state and honors server-requested error expansion", () => {
  for (const [before, server, expected] of [
    [false, false, false], [true, false, true], [false, true, true], [true, true, true]
  ]) {
    const el = { open: before, hasAttribute: () => el.open }
    const hook = { ...hooks.DetailsKeepOpen, el }
    hook.mounted()
    hook.beforeUpdate()
    el.open = server
    hook.updated()
    assert.equal(el.open, expected)
  }
})

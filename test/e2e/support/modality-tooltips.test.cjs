const { test } = require("node:test")
const assert = require("node:assert/strict")
const { readFileSync } = require("node:fs")
const vm = require("node:vm")

const source = readFileSync("lib/zaq_web/components/design_system/model_modalities.ex", "utf8")
const hookSource = source.match(/export default ([\s\S]*?)\n    <\/script>/)[1]

function fixture() {
  const tooltip = {
    isConnected: true,
    open: false,
    style: {},
    showPopover() { this.open = true },
    hidePopover() { this.open = false },
    getBoundingClientRect: () => ({ width: 80, height: 20 })
  }
  const el = { addEventListener() {}, contains: value => value === trigger }
  const trigger = {
    isConnected: true,
    parentElement: null,
    getAttribute: () => "tooltip",
    getBoundingClientRect: () => ({ left: 50, right: 80, top: 60, bottom: 90 }),
    closest: selector => selector === ".zaq-model-modality-trigger" ? trigger : null
  }
  const definition = vm.runInNewContext(`(${hookSource})`, {
    document: {
      documentElement: { clientWidth: 390 },
      getElementById: () => tooltip,
      addEventListener() {}
    },
    window: { innerHeight: 844, addEventListener() {} }
  })
  const hook = { ...definition, el }
  hook.mounted()
  return { hook, tooltip, trigger }
}

test("touch-opened tooltips ignore compatibility mouse leave, mouse-opened ones do not", () => {
  for (const pointerType of ["touch", "mouse"]) {
    const { hook, tooltip, trigger } = fixture()
    hook.onPointerDown({ target: trigger, pointerType })
    hook.onClick({ target: trigger, stopPropagation() {} })
    hook.onPointerLeave({ pointerType: "mouse", relatedTarget: null })
    assert.equal(tooltip.open, pointerType === "touch")
  }
})

test("touch tooltips still close on full clipping, outside click, blur and Escape", () => {
  for (const dismiss of [
    hook => { hook.visibleTriggerRect = () => null; hook.position() },
    hook => hook.onOutside({ target: null }),
    hook => hook.onLeave({ relatedTarget: null }),
    hook => hook.onKey({ key: "Escape", stopPropagation() {} })
  ]) {
    const { hook, tooltip, trigger } = fixture()
    hook.show(trigger, true)
    dismiss(hook)
    assert.equal(tooltip.open, false)
  }
})

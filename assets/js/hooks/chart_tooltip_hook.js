const TOOLTIP_ID = "bo-chart-tooltip"

function clamp(value, min, max) {
  if (value < min) return min
  if (value > max) return max
  return value
}

function ensureTooltip() {
  let tooltip = document.getElementById(TOOLTIP_ID)

  if (tooltip) return tooltip

  tooltip = document.createElement("div")
  tooltip.id = TOOLTIP_ID
  tooltip.style.cssText = "position:fixed; z-index:1200; pointer-events:none; opacity:0; transform:translateY(4px); transition:opacity 140ms ease, transform 140ms ease; border-radius:10px; border:1px solid rgba(15,23,42,0.18); background:rgba(15,23,42,0.95); box-shadow:0 14px 30px rgba(15,23,42,0.22); color:#e2e8f0; padding:8px 10px; min-width:120px; max-width:220px; font-family:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;"

  tooltip.innerHTML = [
    "<div style=\"display:flex;align-items:center;gap:6px;margin-bottom:4px;\">",
    "<span data-tip-dot style=\"display:inline-block;width:8px;height:8px;border-radius:999px;background:#03b6d4;\"></span>",
    "<span data-tip-label style=\"font-size:11px;color:#cbd5e1;letter-spacing:0.03em;text-transform:uppercase;\"></span>",
    "</div>",
    "<div data-tip-value style=\"font-size:12px;color:#f8fafc;font-weight:700;\"></div>"
  ].join("")

  document.body.appendChild(tooltip)
  return tooltip
}

const ChartTooltip = {
  mounted() {
    this.tooltip = ensureTooltip()
    this.tooltipDot = this.tooltip.querySelector("[data-tip-dot]")
    this.tooltipLabel = this.tooltip.querySelector("[data-tip-label]")
    this.tooltipValue = this.tooltip.querySelector("[data-tip-value]")
    this.activeTarget = null

    this.onMouseOver = (event) => {
      const target = this.findTarget(event)
      if (!target) return

      this.activeTarget = target
      this.showFromTarget(target, event.clientX, event.clientY)
    }

    this.onMouseMove = (event) => {
      if (!this.activeTarget) return
      this.position(event.clientX, event.clientY)
    }

    this.onMouseOut = (event) => {
      if (!this.activeTarget) return

      const nextTarget = event.relatedTarget?.closest?.("[data-tip-value]")

      if (nextTarget && this.el.contains(nextTarget)) {
        this.activeTarget = nextTarget
        this.showFromTarget(nextTarget, event.clientX, event.clientY)
        return
      }

      this.activeTarget = null
      this.hide()
    }

    this.onFocusIn = (event) => {
      const target = this.findTarget(event)
      if (!target) return

      const rect = target.getBoundingClientRect()
      this.activeTarget = target
      this.showFromTarget(target, rect.left + rect.width / 2, rect.top)
    }

    this.onFocusOut = (event) => {
      const nextTarget = event.relatedTarget?.closest?.("[data-tip-value]")

      if (nextTarget && this.el.contains(nextTarget)) {
        this.activeTarget = nextTarget
        return
      }

      this.activeTarget = null
      this.hide()
    }

    this.onClick = (event) => {
      const target = this.findTarget(event)
      if (!target) return

      const rect = target.getBoundingClientRect()
      this.activeTarget = target
      this.showFromTarget(target, rect.left + rect.width / 2, rect.top + rect.height / 2)
    }

    this.onViewportChange = () => {
      if (!this.activeTarget) return
      this.hide()
    }

    this.el.addEventListener("mouseover", this.onMouseOver)
    this.el.addEventListener("mousemove", this.onMouseMove)
    this.el.addEventListener("mouseout", this.onMouseOut)
    this.el.addEventListener("focusin", this.onFocusIn)
    this.el.addEventListener("focusout", this.onFocusOut)
    this.el.addEventListener("click", this.onClick)

    window.addEventListener("scroll", this.onViewportChange, true)
    window.addEventListener("resize", this.onViewportChange)
  },

  destroyed() {
    this.el.removeEventListener("mouseover", this.onMouseOver)
    this.el.removeEventListener("mousemove", this.onMouseMove)
    this.el.removeEventListener("mouseout", this.onMouseOut)
    this.el.removeEventListener("focusin", this.onFocusIn)
    this.el.removeEventListener("focusout", this.onFocusOut)
    this.el.removeEventListener("click", this.onClick)

    window.removeEventListener("scroll", this.onViewportChange, true)
    window.removeEventListener("resize", this.onViewportChange)

    if (this.activeTarget) {
      this.activeTarget = null
      this.hide()
    }
  },

  findTarget(event) {
    const target = event.target.closest("[data-tip-value]")
    if (!target) return null
    if (!this.el.contains(target)) return null
    return target
  },

  showFromTarget(target, clientX, clientY) {
    this.tooltipLabel.textContent = target.dataset.tipLabel || "Metric"
    this.tooltipValue.textContent = target.dataset.tipValue || "--"
    this.tooltipDot.style.backgroundColor = target.dataset.tipColor || "#03b6d4"

    this.tooltip.style.opacity = "1"
    this.tooltip.style.transform = "translateY(0px)"

    this.position(clientX, clientY)
  },

  position(clientX, clientY) {
    const gap = 14
    const rect = this.tooltip.getBoundingClientRect()

    let left = clientX + gap
    let top = clientY + gap

    if (left + rect.width > window.innerWidth - 8) {
      left = clientX - rect.width - gap
    }

    if (top + rect.height > window.innerHeight - 8) {
      top = clientY - rect.height - gap
    }

    this.tooltip.style.left = `${clamp(left, 8, window.innerWidth - rect.width - 8)}px`
    this.tooltip.style.top = `${clamp(top, 8, window.innerHeight - rect.height - 8)}px`
  },

  hide() {
    this.tooltip.style.opacity = "0"
    this.tooltip.style.transform = "translateY(4px)"
  }
}

export default ChartTooltip

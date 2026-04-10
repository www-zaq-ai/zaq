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
  tooltip.className = "zaq-chart-tooltip"

  tooltip.innerHTML = [
    "<div class=\"zaq-chart-tooltip-header\">",
    "<span data-tip-dot class=\"zaq-chart-tooltip-dot\"></span>",
    "<span data-tip-label class=\"zaq-chart-tooltip-label\"></span>",
    "</div>",
    "<div data-tip-value class=\"zaq-chart-tooltip-value\"></div>"
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
    this.tooltipDot.style.backgroundColor = target.dataset.tipColor || "var(--zaq-color-accent)"

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
